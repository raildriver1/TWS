unit RA3;

// ============================================================================
// РА-3 (Орлан) — звуковая модель для TWS
//
// Активируется когда LocoGlobal содержит "RA3" (см. UnitMain.pas, детект
// по подстроке через Pos('RA3', UpperCase(LocoGlobal)) > 0).
//
// Звуки взяты из открытого проекта RRS RA-3 v4.0.5 (Дмитрий Притыкин,
// https://gitlab.com/maisvendoo/ra3) — лежат в TWS\RA3\.
//
// Перечень звуков:
//   disel-start.wav        — стартер запуска дизеля
//   disel-work-nominal.wav — холостые обороты (loop)
//   disel-work-high.wav    — высокие обороты под тягой (loop)
//   disel-stop.wav         — остановка дизеля
//   km.wav                 — клик контроллера машиниста (A/D)
//   switcher.wav           — реверсор / тумблер стояночного тормоза
//   tumbler.wav            — общий тумблер (БВ, ЭПТ, фары)
//   395_2.wav              — наполнение тормозной магистрали (кран II)
//   395_5.wav              — опорожнение (кран V)
//   395_vypusk.wav         — выпуск воздуха при экстренном
//   pb_brake.wav           — стояночный тормоз
//   epk.wav                — свисток ЭПК
//   svistok.wav            — свисток
//   tifon.wav              — тифон
//   sand.wav               — песок
//   passdoor.wav           — пассажирские двери
//   fuel_pump.wav          — топливный насос
//   relay.wav              — реле
//   blok_beep_3.wav        — БЛОК пик
//   5-10.wav .. 120-~.wav  — звуки качения по скоростным диапазонам
// ============================================================================

interface

   uses VR242;

type ra3_ = class (TObject)
    private
      soundDir: String;

      vr242__: vr242_;

      // ── флаги состояния ──
      DieselRunning:  Boolean;       // дизель запущен (loop nominal/high)
      DieselWasRun:   Boolean;       // был ли запущен (для disel-stop)
      DieselHighMode: Boolean;       // true = high RPM активен сейчас (защита от стакания)
      PrevSpeedRange: Integer;       // предыдущий диапазон скорости (для звуков качения)
      PrevTickAtSwitch: Cardinal;    // отбойник для тумблеров (анти-стакание)
      PrevKMMode:     Integer;       // -1 / 0 / +1 — предыдущий режим КМ (для km.wav)
      PrevKeyX:       Byte;          // edge-detect для X (песок)

      // ── процедуры ──
      procedure diesel_step();
      procedure km_step();
      procedure reverser_step();
      procedure brake395_step();
      procedure bv_step();
      procedure ept_step();
      procedure hLights_step();
      procedure door_step();
      procedure rolling_step();
      procedure sand_step();
    protected

    public

      procedure step();

    published

    constructor Create;

   end;

implementation

   uses UnitMain, soundManager, Bass, SysUtils, Math, Windows;

   // ----------------------------------------------------
   //
   // ----------------------------------------------------
   constructor ra3_.Create;
   begin
      soundDir := 'TWS\RA3\';

      vr242__ := vr242_.Create(False);

      DieselRunning   := False;
      DieselWasRun    := False;
      DieselHighMode  := False;
      PrevSpeedRange  := -1;
      PrevTickAtSwitch:= 0;
      PrevKMMode      := 0;
      PrevKeyX        := 0;
   end;

   // ----------------------------------------------------
   // Главный шаг — вызывается каждый тик из UnitMain
   // ----------------------------------------------------
   procedure ra3_.step();
   begin
      if FormMain.cbCabinClicks.Checked = True then begin
         km_step();
         reverser_step();
         brake395_step();
         bv_step();
         ept_step();
         hLights_step();
         sand_step();
         vr242__.step();
      end;

      if FormMain.cbVspomMash.Checked = True then begin
         diesel_step();
         door_step();
      end;

      if FormMain.cbLocPerestuk.Checked = True then begin
         rolling_step();
      end;
   end;

   // ----------------------------------------------------
   // Дизель: старт по БВ, остановка при выкл, циклирование nominal/high по KM_Pos
   // ----------------------------------------------------
   procedure ra3_.diesel_step();
   begin
      // Старт дизеля при включении БВ
      if (BV = 1) and (PrevBV = 0) and (DieselRunning = False) then begin
         CompressorF      := StrNew(PChar(soundDir + 'disel-start.wav'));
         CompressorCycleF := StrNew(PChar(soundDir + 'disel-work-nominal.wav'));
         isPlayCompressor := False;
         DieselRunning    := True;
         DieselWasRun     := True;
      end;

      // Остановка дизеля при выключении БВ
      if (BV = 0) and (PrevBV = 1) and (DieselRunning = True) then begin
         CompressorF      := StrNew(PChar(soundDir + 'disel-stop.wav'));
         CompressorCycleF := PChar('');
         isPlayCompressor := False;
         DieselRunning    := False;
      end;

      // Переключение nominal/high — ТОЛЬКО при пересечении порога,
      // не на каждом изменении KM_Pos (иначе loop рестартится бесконечно
      // и звуки стакаются).
      // KM_Pos_1 < 32768 → тяга (UInt16: positive), >= 32768 → тормоз
      // Позиции 0..2 — nominal, 3..5 — high
      if DieselRunning then begin
         if (KM_Pos_1 >= 3) and (KM_Pos_1 < 32768) then begin
            // должны быть в high
            if not DieselHighMode then begin
               CompressorCycleF := StrNew(PChar(soundDir + 'disel-work-high.wav'));
               isPlayCompressor := False;
               DieselHighMode := True;
            end;
         end
         else begin
            // должны быть в nominal
            if DieselHighMode then begin
               CompressorCycleF := StrNew(PChar(soundDir + 'disel-work-nominal.wav'));
               isPlayCompressor := False;
               DieselHighMode := False;
            end;
         end;
      end;
   end;

   // ----------------------------------------------------
   // Клик контроллера машиниста — играем ТОЛЬКО при смене режима:
   //   нейтраль → тяга      (KM_Pos: 0 → 1..5)
   //   тяга → нейтраль      (KM_Pos: 1..5 → 0)
   //   нейтраль → тормоз    (KM_Pos: 0 → 251..255)
   //   тормоз → нейтраль    (KM_Pos: 251..255 → 0)
   //   тяга → тормоз / тормоз → тяга (через 0 в RRS, но на всякий)
   //
   // НЕ играем когда внутри одного режима меняется уровень (1→2, 2→3, ...).
   // Это соответствует реальному РА-3 — щелчок только на пороге выхода из/в
   // нейтраль (и при Ctrl+D, который тоже сбрасывает в 0).
   // ----------------------------------------------------
   procedure ra3_.km_step();
   var
      curMode: Integer;
   begin
      // Определяем текущий режим из KM_Pos_1 (UInt16: 0=neutral, 1..5=trac, 65531..65535=brake)
      if (KM_Pos_1 >= 1) and (KM_Pos_1 < 32768) then curMode := 1
      else if KM_Pos_1 >= 32768                  then curMode := -1
      else                                            curMode := 0;

      if curMode <> PrevKMMode then begin
         CabinClicksF := StrNew(PChar(soundDir + 'km.wav'));
         isPlayCabinClicks := False;
         PrevKMMode := curMode;
      end;
   end;

   // ----------------------------------------------------
   // Реверсор: щелчок при смене ReversorPos
   // ----------------------------------------------------
   procedure ra3_.reverser_step();
   begin
      if ReversorPos <> PrevReversorPos then begin
         CabinClicksF := StrNew(PChar(soundDir + 'switcher.wav'));
         isPlayCabinClicks := False;
      end;
   end;

   // ----------------------------------------------------
   // Кран 395: 2-поездное (наполнение), 5-V (опорожнение), 6-VI (экстр.)
   // ----------------------------------------------------
   procedure ra3_.brake395_step();
   var
      St: String;
   begin
      if KM_395 <> PrevKM_395 then begin
         St := '';
         case KM_395 of
            1, 2:    St := '395_2.wav';        // I, II — отпуск/поездное (наполнение)
            5:       St := '395_5.wav';        // V — служебное торможение (опорожнение)
            6:       St := '395_vypusk.wav';   // VI — экстренное торможение
         else
            St := 'switcher.wav';              // III/IV — перекрыша, нейтральный клик
         end;
         if St <> '' then begin
            CabinClicksF := StrNew(PChar(soundDir + St));
            isPlayCabinClicks := False;
         end;
      end;
   end;

   // ----------------------------------------------------
   // Тумблеры — БВ / ЭПТ / Фары через общий LocoPowerEquipmentF.
   // Если несколько тумблеров меняются в одном кадре, играем ТОЛЬКО первый,
   // плюс минимум 100мс между запусками — иначе звуки стакаются.
   // ----------------------------------------------------
   procedure ra3_.bv_step();
   begin
      if (BV <> PrevBV) and (GetTickCount - PrevTickAtSwitch > 100) then begin
         LocoPowerEquipmentF := StrNew(PChar(soundDir + 'tumbler.wav'));
         isPlayLocoPowerEquipment := False;
         PrevTickAtSwitch := GetTickCount;
      end;
   end;

   procedure ra3_.ept_step();
   begin
      if (EPT <> PrevEPT) and (GetTickCount - PrevTickAtSwitch > 100) then begin
         LocoPowerEquipmentF := StrNew(PChar(soundDir + 'tumbler.wav'));
         isPlayLocoPowerEquipment := False;
         PrevTickAtSwitch := GetTickCount;
      end;
   end;

   procedure ra3_.hLights_step();
   begin
      if (Highlights <> PrevHighLights) and (GetTickCount - PrevTickAtSwitch > 100) then begin
         LocoPowerEquipmentF := StrNew(PChar(soundDir + 'tumbler.wav'));
         isPlayLocoPowerEquipment := False;
         PrevTickAtSwitch := GetTickCount;
      end;
   end;

   // ----------------------------------------------------
   // Двери (passdoor.wav, кратковременный звук)
   // ----------------------------------------------------
   procedure ra3_.door_step();
   begin
      if LDOOR <> PrevLDOOR then begin
         TWS_PlayLDOOR(PChar(soundDir + 'passdoor.wav'));
      end;
      if RDOOR <> PrevRDOOR then begin
         TWS_PlayRDOOR(PChar(soundDir + 'passdoor.wav'));
      end;
   end;

   // ----------------------------------------------------
   // Звуки качения по скоростным диапазонам
   // (5-10, 10-20, 20-30, 30-40, 40-45, 45-50, 50-60, 60-70, 70-80,
   //  80-90, 90-110, 110-120, 120-~)
   // ----------------------------------------------------
   procedure ra3_.rolling_step();
   var
      curRange: Integer;
      St: String;
   begin
      // Маппинг скорости в диапазон (индексы для сравнения)
      if      Speed < 5   then curRange := 0
      else if Speed < 10  then curRange := 1     // 5-10
      else if Speed < 20  then curRange := 2     // 10-20
      else if Speed < 30  then curRange := 3     // 20-30
      else if Speed < 40  then curRange := 4     // 30-40
      else if Speed < 45  then curRange := 5     // 40-45
      else if Speed < 50  then curRange := 6     // 45-50
      else if Speed < 60  then curRange := 7     // 50-60
      else if Speed < 70  then curRange := 8     // 60-70
      else if Speed < 80  then curRange := 9     // 70-80
      else if Speed < 90  then curRange := 10    // 80-90
      else if Speed < 110 then curRange := 11    // 90-110
      else if Speed < 120 then curRange := 12    // 110-120
      else                     curRange := 13;   // 120-~

      // Если диапазон сменился — переключаем loop
      if curRange <> PrevSpeedRange then begin
         case curRange of
            0:  St := '';                  // ниже 5 км/ч — тишина (механическая часть на стуках)
            1:  St := '5-10.wav';
            2:  St := '10-20.wav';
            3:  St := '20-30.wav';
            4:  St := '30-40.wav';
            5:  St := '40-45.wav';
            6:  St := '45-50.wav';
            7:  St := '50-60.wav';
            8:  St := '60-70.wav';
            9:  St := '70-80.wav';
            10: St := '80-90.wav';
            11: St := '90-110.wav';
            12: St := '110-120.wav';
            13: St := '120-~.wav';
         else
            St := '';
         end;

         if St <> '' then begin
            TWS_PlayDrivingNoise(PChar(soundDir + St));
         end;

         PrevSpeedRange := curRange;
      end;
   end;

   // ----------------------------------------------------
   // Песок (X) — играем звук на нажатии. sand.wav — короткий клик
   // включения подачи; для непрерывного шипения использовалась бы
   // петля, но в RRS-наборе sand.wav уже включает и подачу, и хлюпок.
   // ----------------------------------------------------
   procedure ra3_.sand_step();
   begin
      // Rising edge — нажали X впервые
      if (GetAsyncKeyState(88) <> 0) and (PrevKeyX = 0) then begin
         CabinClicksF := StrNew(PChar(soundDir + 'sand.wav'));
         isPlayCabinClicks := False;
         PrevKeyX := 1;
      end;
      if GetAsyncKeyState(88) = 0 then PrevKeyX := 0;
   end;

end.
