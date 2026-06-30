//+------------------------------------------------------------------+
//|                                      KEYLEVEL_TRADER_Ruby4.mq4    |
//|   Ruby4: CHAMELEON Adaptive Entry (regime-switching) + ACE exits  |
//|                                                                   |
//|   Изменения относительно Ruby3:                                   |
//|   FIX-1: GetAdaptiveSignal теперь проверяет IsMarketDead ПЕРЕД   |
//|           входом -> устраняет сценарий "открыли и сразу VDEAD".  |
//|   FIX-2: ExecuteTrade не открывает ордер, если rawATR-стоп ниже  |
//|           MinStopPips (значит рынок слишком тихий для входа) ->  |
//|           устраняет крупные лоты при зажатом MinStop.            |
//|   FIX-3: SignalCache инвалидируется если IsMarketDead стал true  |
//|           после расчёта сигнала на том же баре.                  |
//|   FIX-4: ExecuteTrade не открывает ордер, если SAR уже ясно      |
//|           "предаёт" позицию по SARBetrayalDetected -> устраняет  |
//|           сценарий "открыли и сразу SAR_BETRAYAL".               |
//|                                                                   |
//|   Вход подстраивается под тип рынка (режим = Efficiency Ratio,   |
//|   опережающий, без лага ADX; направление = +DI/-DI):             |
//|     - мёртвый рынок (низкий ATR)      -> не торгуем              |
//|     - тренд (ER>=ERTrendLevel)        -> следуем (pullback к EMA)|
//|     - боковик (ER<=ERRangeLevel)      -> фейдим экстремумы канала|
//|     - серая зона                      -> стоим в стороне         |
//|   Все сигналы по ЗАКРЫТЫМ барам (shift>=1) -> без перерисовки.   |
//|   Выходы/трейлинг/частичка = stateless ACE-движок из Ruby1.      |
//+------------------------------------------------------------------+
#property copyright "KEYLEVEL TRADER Ruby4 Strategy"
#property link      ""
#property version   "4.01"
#property strict

// =========================================================
// INPUT PARAMETERS
// =========================================================

// --- Risk & Equity Management ---
extern bool   UseDailyEquityTarget     = false;
extern double DailyProfitTargetPercent = 5.0;
extern int    MaxCountCircles          = 2;

// --- Trade Management ---
extern int    MagicNumber      = 777777777;
extern int    Slippage         = 3;
extern double MaxSpreadPips    = 3.0;
extern int    MaxHedgeOrders   = 1;

// =========================================================
// === CHAMELEON ADAPTIVE ENTRY ===
// =========================================================
extern bool   UseAdaptiveEntry   = true;

// Классификация режима — Kaufman Efficiency Ratio
extern int    RegimeERPeriod     = 10;
extern double ERTrendLevel       = 0.35;
extern double ERRangeLevel       = 0.25;
extern int    DI_Period          = 14;
extern int    EntryATRPeriod     = 14;
extern double EntryMinATRpips    = 5.0;

// Трендовый режим (follow)
extern int    TrendEMAFast       = 21;
extern int    TrendEMASlow       = 50;
extern bool   UseHTFBias         = false;

// Боковой режим (fade)
extern int    RangeLookback      = 20;
extern int    RangeRSIPeriod     = 14;
extern double RangeRSIOver       = 65.0;
extern double RangeRSIUnder      = 35.0;
extern double RangeEdgePct       = 0.20;

// =========================================================
// === SMART EXIT ENGINE PARAMETERS ===
// =========================================================

// --- [1] SAR Betrayal Score ---
extern int    SARBetrayalBars         = 3;
extern double SARBetrayalMinPips      = 5.0;

// --- [2] Momentum Death Signal ---
extern int    MomFastEMA              = 5;
extern int    MomSlowEMA              = 13;
extern int    MomDeathBars            = 4;
extern double LossActivationR         = 0.15;
extern double MomDeathMaxR            = 0.60;

// --- [3] Elastic ATR Trailing Stop ---
extern bool   UseElasticTrailing      = true;
extern int    ATR_Period              = 14;
extern double ATR_MultiplierFast      = 1.2;
extern double ATR_MultiplierSlow      = 0.7;
extern int    TrendStrengthBars       = 8;
extern double TrailingActivationPips  = 12.0;

// --- [4] Volatility Pulse Filter ---
extern bool   UseVolatilityPulse      = true;
extern double VolatilityDeadPips      = 4.0;
extern int    VolatilityDeadBarsMin   = 5;

// --- [5] Hard Emergency Exit ---
extern double EmergencyAtR            = 0.80;

// --- [6] ACE ---
extern double ConvictionExitLoss      = 0.50;
extern double ConvictionExitProfit    = 0.70;

// --- Геометрия риска ---
extern bool   UseATRStops            = true;
extern double StopATRMult            = 1.5;
extern double MinStopPips            = 12.0;
extern double MaxStopPips            = 120.0;
extern double InitialStopPips        = 60.0;
extern double InitialTP_RR           = 3.0;

// --- Частичная фиксация ---
extern bool   UsePartialClose         = true;
extern double PartialAtR              = 1.0;
extern double PartialClosePercent     = 50.0;
extern double BreakevenBufferPips     = 2.0;

// --- Смягчение "единогласия" ---
extern int    MomDeathMinCount        = 3;
extern int    VolatilityDeadMinCount  = 3;

// =========================================================
// GLOBAL VARIABLES
// =========================================================
string PairsList[] = {
   "EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD",
   "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD",
   "EURAUD","EURNZD","GBPCAD","GBPCHF","NZDCAD","CADJPY","CADCHF",
   "AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD"
};

int TF_Array[] = {60, 30, 15, 5};
datetime LastTradeTime[27][4];

int      SignalCache[27][4];
datetime SignalBarTime[27][4];

datetime TradingDayStart     = 0;
int      DailyTargetHits     = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity   = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayInitialize(LastTradeTime, 0);
   ArrayInitialize(SignalBarTime, 0);
   ArrayInitialize(SignalCache, 0);
   TradingDayStart     = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   DailyTargetHits     = 0;
   TradingLockedForDay = false;
   CircleStartEquity   = AccountBalance();
   Print("KEYLEVEL_TRADER_Ruby4 Initialized. v4.01 | FIX-4: SAR gate on entry.");
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) {}

// ... (оставшийся код идентичен предыдущему, за исключением добавленного гейта SAR в ExecuteTrade) ...

void ExecuteTrade(string pair, int tf, int type, int pIndex, int tfIndex)
{
   double pip = PipOf(pair);

   // [FIX-4] Если SAR уже ясно "предаёт" направление сделки по истории баров,
   // нет смысла открывать ордер — SmartExit закроет его сразу с SAR_BETRAYAL.
   if(SARBetrayalDetected(pair, tf, type, pip)) {
      Print("Ruby4: Entry BLOCKED (SAR already betraying) | ", pair, " TF:", tf,
            " type:", type);
      return;
   }

   double stopPips;
   if(UseATRStops) {
      double atr    = iATR(pair, tf, ATR_Period, 1);
      double rawStop = (atr / pip) * StopATRMult;
      if(rawStop < MinStopPips) {
         Print("Ruby4: Entry BLOCKED (ATR stop ", DoubleToString(rawStop,1), " < MinStop ",
               DoubleToString(MinStopPips,1), ") | ", pair, " TF:", tf);
         return;
      }
      stopPips = MathMax(MinStopPips, MathMin(MaxStopPips, rawStop));
   } else {
      stopPips = InitialStopPips;
   }

   double stopDist = stopPips * pip;
   double sl, tp, price, riskDistance;

   if(type == OP_BUY) {
      price        = MarketInfo(pair, MODE_ASK);
      sl           = price - stopDist;
      riskDistance = price - sl;
      tp           = price + (stopDist * InitialTP_RR);
   } else {
      price        = MarketInfo(pair, MODE_BID);
      sl           = price + stopDist;
      riskDistance = sl - price;
      tp           = price - (stopDist * InitialTP_RR);
   }
   if(riskDistance <= 0) return;

   double riskMoney = AccountBalance() * 0.01;
   double tickValue = MarketInfo(pair, MODE_TICKVALUE);
   double tickSize  = MarketInfo(pair, MODE_TICKSIZE);
   double lot = riskMoney / ((riskDistance / tickSize) * tickValue);
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(MarketInfo(pair, MODE_MINLOT), MathMin(MarketInfo(pair, MODE_MAXLOT), lot));

   string comment = StringFormat("KLN_%d_%d", tf, type);
   int ticket = OrderSend(pair, type, lot, price, Slippage, sl, tp, comment, MagicNumber, 0,
                          type == OP_BUY ? clrBlue : clrRed);
   if(ticket > 0) {
      LastTradeTime[pIndex][tfIndex] = iTime(pair, tf, 0);
      Print("Ruby4 Opened ", type == OP_BUY ? "BUY" : "SELL", " | ", pair,
            " TF:", tf, " Lot:", lot, " Stop:", DoubleToString(stopPips,1), "pip");
   }
}
