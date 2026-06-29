//+------------------------------------------------------------------+
//|                                      KEYLEVEL_TRADER_Ruby2.mq4    |
//|   Ruby2: CHAMELEON Adaptive Entry (regime-switching) + ACE exits  |
//|                                                                   |
//|   Вход подстраивается под тип рынка (режим = Efficiency Ratio,    |
//|   опережающий, без лага ADX; направление = +DI/-DI):              |
//|     - мёртвый рынок (низкий ATR)      -> не торгуем               |
//|     - тренд (ER>=ERTrendLevel)        -> следуем (pullback к EMA) |
//|     - боковик (ER<=ERRangeLevel)      -> фейдим экстремумы канала |
//|     - серая зона                      -> стоим в стороне          |
//|   Все сигналы по ЗАКРЫТЫМ барам (shift>=1) -> без перерисовки.    |
//|   Выходы/трейлинг/частичка = stateless ACE-движок из Ruby1.       |
//+------------------------------------------------------------------+
#property copyright "KEYLEVEL TRADER Ruby2 Strategy"
#property link      ""
#property version   "3.10"
#property strict

// =========================================================
// INPUT PARAMETERS
// =========================================================

// --- Risk & Equity Management ---
extern bool   UseDailyEquityTarget     = true;
extern double DailyProfitTargetPercent = 5.0;
extern int    MaxCountCircles          = 2;

// --- Trade Management ---
extern int    MagicNumber      = 20260630;
extern int    Slippage         = 3;
extern double MaxSpreadPips    = 3.0;
extern int    MaxHedgeOrders   = 1;

// =========================================================
// === [NEW] CHAMELEON ADAPTIVE ENTRY ===
// =========================================================
extern bool   UseAdaptiveEntry   = true;   // false -> старый вход (fallback для A/B)

// Классификация режима — Kaufman Efficiency Ratio (опережающий, без лага ADX)
// ER in [0..1]: ~1 = чистое направленное движение (тренд), ~0 = пила (боковик).
extern int    RegimeERPeriod     = 10;      // окно ER
extern double ERTrendLevel       = 0.35;    // ER >= -> трендовый режим
extern double ERRangeLevel       = 0.25;    // ER <= -> боковой режим (между = пропуск). ВВЕРХ: больше range, меньше молчания
extern int    DI_Period          = 14;      // период +DI/-DI (используется ТОЛЬКО для направления)
extern int    EntryATRPeriod     = 14;
extern double EntryMinATRpips    = 5.0;     // ниже -> рынок мёртв, не входим

// Трендовый режим (follow)
extern int    TrendEMAFast       = 21;
extern int    TrendEMASlow       = 50;
extern bool   UseHTFBias         = false;   // выкл по умолчанию: на M5/M15 H1-фильтр режет частоту

// Боковой режим (fade)
extern int    RangeLookback      = 20;      // период канала Donchian
extern int    RangeRSIPeriod     = 14;
extern double RangeRSIOver       = 65.0;    // перекупленность (ослаблено -> больше range-входов)
extern double RangeRSIUnder      = 35.0;    // перепроданность (ослаблено -> больше range-входов)
extern double RangeEdgePct       = 0.20;    // "край" канала = эта доля ширины (компромисс)

// =========================================================
// === SMART EXIT ENGINE PARAMETERS (как в Ruby1) ===
// =========================================================

// --- [1] SAR Betrayal Score ---
extern int    SARBetrayalBars         = 3;
extern double SARBetrayalMinPips      = 5.0;

// --- [2] Momentum Death Signal ---
// Пороги потерь — в долях R (а не в пунктах), чтобы быть универсальными при ATR-стопе.
extern int    MomFastEMA              = 5;
extern int    MomSlowEMA              = 13;
extern int    MomDeathBars            = 4;
extern double LossActivationR         = 0.15;  // умные выходы в минусе включаются с -0.15R
extern double MomDeathMaxR            = 0.60;  // momentum-death действует до -0.60R

// --- [3] Elastic ATR Trailing Stop ---
extern bool   UseElasticTrailing      = true;
extern int    ATR_Period              = 14;
extern double ATR_MultiplierFast      = 1.2;
extern double ATR_MultiplierSlow      = 0.7;
extern int    TrendStrengthBars       = 8;
extern double TrailingActivationPips  = 12.0;

// --- [4] Volatility Pulse Filter ---
// Порог "мёртвого" рынка в ПУНКТАХ (абсолютный ATR в цене не универсален: JPY vs EURUSD).
extern bool   UseVolatilityPulse      = true;
extern double VolatilityDeadPips      = 4.0;
extern int    VolatilityDeadBarsMin   = 5;

// --- [5] Hard Emergency Exit (в долях R, ранний бэйл перед брокерским стопом -1R) ---
extern double EmergencyAtR            = 0.80;

// --- [6] ACE ---
extern double ConvictionExitLoss     = 0.50;
extern double ConvictionExitProfit   = 0.70;

// --- Геометрия риска ---
// ATR-стоп = главный фактор универсальности: один стоп в пунктах не подходит и
// EURUSD, и GBPJPY. Стоп = StopATRMult * ATR(TF ордера), зажат в [Min..Max] пунктов.
// R (для частички/эмердженси) восстанавливается из TP -> stateless и restart-safe.
extern bool   UseATRStops            = true;   // false -> фикс. InitialStopPips (как Ruby1)
extern double StopATRMult            = 1.5;    // стоп = этот множитель * ATR
extern double MinStopPips            = 12.0;   // нижний предел стопа (защита от микро-стопа)
extern double MaxStopPips            = 120.0;  // верхний предел стопа
extern double InitialStopPips        = 60.0;   // fallback при UseATRStops=false
extern double InitialTP_RR           = 3.0;    // TP = R * этого

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

// Кеш сигнала входа. Adaptive-вход считается по закрытым барам -> инвариантен внутри
// бара, поэтому пересчитываем раз на новый бар (быстро и без изменения логики).
int      SignalCache[27][4];
datetime SignalBarTime[27][4];

datetime TradingDayStart    = 0;
int      DailyTargetHits    = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity  = 0;

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
   Print("KEYLEVEL_TRADER_Ruby2 Initialized. CHAMELEON entry + ACE exits. CircleEquity: ", CircleStartEquity);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void ResetDailyCycleStateIfNeeded()
{
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(TradingDayStart != todayStart) {
      TradingDayStart     = todayStart;
      DailyTargetHits     = 0;
      TradingLockedForDay = false;
      CircleStartEquity   = AccountBalance();
      Print("New trading day. Reset. CircleStartEquity: ", CircleStartEquity);
   }
}

//+------------------------------------------------------------------+
bool CheckAndExecuteDailyTarget()
{
   if(!UseDailyEquityTarget) return false;
   if(TradingLockedForDay) return true;
   if(CircleStartEquity <= 0) return false;

   double targetEquity  = CircleStartEquity * (1.0 + (DailyProfitTargetPercent / 100.0));
   double currentEquity = AccountEquity();

   if(currentEquity >= targetEquity) {
      Print("!!! CIRCLE TARGET REACHED !!! Equity: ", currentEquity, " >= ", targetEquity);
      CloseAllOpenTrades();
      DailyTargetHits++;

      if(DailyTargetHits >= MaxCountCircles) {
         TradingLockedForDay = true;
         Print("Trading locked until next day.");
      } else {
         CircleStartEquity = AccountBalance();
         Print("New circle. Base: ", CircleStartEquity);
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseAllOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      for(int attempt = 1; attempt <= 3; attempt++) {
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY)
            ? MarketInfo(OrderSymbol(), MODE_BID)
            : MarketInfo(OrderSymbol(), MODE_ASK);

         if(OrderClose(OrderTicket(), OrderLots(), closePrice, Slippage, clrGreen)) break;

         int err = GetLastError();
         if(err == ERR_OFF_QUOTES || err == ERR_REQUOTE || err == ERR_PRICE_CHANGED) Sleep(500);
         else break;
      }
   }
}

bool CloseOrderByTicket(int ticket, string reason)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return false;

   for(int attempt = 1; attempt <= 3; attempt++) {
      RefreshRates();
      double closePrice = (OrderType() == OP_BUY)
         ? MarketInfo(OrderSymbol(), MODE_BID)
         : MarketInfo(OrderSymbol(), MODE_ASK);

      if(OrderClose(ticket, OrderLots(), closePrice, Slippage, clrOrange)) {
         Print("SmartExit [", reason, "] closed ticket ", ticket,
               " Pair: ", OrderSymbol(),
               " P&L pips: ", DoubleToString(
                  (OrderType() == OP_BUY ?
                     (MarketInfo(OrderSymbol(), MODE_BID) - OrderOpenPrice()) :
                     (OrderOpenPrice() - MarketInfo(OrderSymbol(), MODE_ASK))
                  ) / (
                     (MarketInfo(OrderSymbol(), MODE_DIGITS) == 3 || MarketInfo(OrderSymbol(), MODE_DIGITS) == 5)
                        ? MarketInfo(OrderSymbol(), MODE_POINT) * 10
                        : MarketInfo(OrderSymbol(), MODE_POINT)
                  ), 1));
         return true;
      }
      int err = GetLastError();
      if(err == ERR_OFF_QUOTES || err == ERR_REQUOTE || err == ERR_PRICE_CHANGED) Sleep(300);
      else break;
   }
   return false;
}

// =========================================================
// Извлечь TF из комментария "KLN_TF_TYPE"
// =========================================================
int GetOrderTF(string comment)
{
   int pos1 = StringFind(comment, "_");
   int pos2 = StringFind(comment, "_", pos1 + 1);
   if(pos1 < 0 || pos2 < 0) return PERIOD_M15;

   int tf = (int)StringToInteger(StringSubstr(comment, pos1 + 1, pos2 - pos1 - 1));
   if(tf == 5)  return PERIOD_M5;
   if(tf == 15) return PERIOD_M15;
   if(tf == 30) return PERIOD_M30;
   if(tf == 60) return PERIOD_H1;
   return PERIOD_M15;
}

//+------------------------------------------------------------------+
//| TIER LOGIC                                                       |
//+------------------------------------------------------------------+
bool IsTimeframeAllowed(string pair, int tf)
{
   string tier1[] = {"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD","EURJPY"};
   string tier2[] = {"GBPJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD","EURAUD","EURNZD","GBPCAD","GBPCHF",
                     "NZDCAD","CADJPY","CADCHF","AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD"};

   for(int i=0; i<ArraySize(tier1); i++) if(pair == tier1[i]) return (tf == 60 || tf == 30 || tf == 15 || tf == 5);
   for(int i=0; i<ArraySize(tier2); i++) if(pair == tier2[i]) return (tf == 60 || tf == 30 || tf == 15);
   return (tf == 60 || tf == 30);
}

double PipOf(string pair)
{
   int d = (int)MarketInfo(pair, MODE_DIGITS);
   return (d == 3 || d == 5) ? MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);
}

// =========================================================
// *** CHAMELEON ADAPTIVE ENTRY ***  (всё по закрытым барам, без перерисовки)
// Возвращает +1 (buy), -1 (sell), 0 (нет сигнала).
// =========================================================
int GetAdaptiveSignal(string pair, int tf)
{
   double pip = PipOf(pair);
   if(pip <= 0) return 0;

   // --- фильтр мёртвого рынка ---
   double atr = iATR(pair, tf, EntryATRPeriod, 1);
   if(atr / pip < EntryMinATRpips) return 0;

   // --- классификация режима по Efficiency Ratio (опережающий, без лага) ---
   double er = EfficiencyRatio(pair, tf, RegimeERPeriod, 1);

   // направление берём у ±DI (сам ADX-уровень больше не используется)
   double pdi = iADX(pair, tf, DI_Period, PRICE_CLOSE, MODE_PLUSDI,  1);
   double mdi = iADX(pair, tf, DI_Period, PRICE_CLOSE, MODE_MINUSDI, 1);

   if(er >= ERTrendLevel) return TrendSignal(pair, tf, pdi, mdi);
   if(er <= ERRangeLevel) return RangeSignal(pair, tf);
   return 0;   // серая зона — стоим в стороне
}

// Kaufman Efficiency Ratio: |смещение| / суммарный путь за period баров.
// 1 = идеальный тренд, 0 = чистая пила. Реагирует мгновенно (нет сглаживания).
double EfficiencyRatio(string pair, int tf, int period, int shift)
{
   if(period < 1) period = 1;
   double change = MathAbs(iClose(pair, tf, shift) - iClose(pair, tf, shift + period));
   double path = 0.0;
   for(int k = 0; k < period; k++)
      path += MathAbs(iClose(pair, tf, shift + k) - iClose(pair, tf, shift + k + 1));
   if(path <= 0.0) return 0.0;
   return change / path;
}

// Тренд: следуем за трендом, входим на откате к быстрой EMA и возврате.
int TrendSignal(string pair, int tf, double pdi, double mdi)
{
   double emaF1 = iMA(pair, tf, TrendEMAFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaS1 = iMA(pair, tf, TrendEMASlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double c1    = iClose(pair, tf, 1);
   double l1    = iLow(pair, tf, 1);
   double h1    = iHigh(pair, tf, 1);
   int    htf   = UseHTFBias ? HTFbias(pair, tf) : 0;

   // восходящий тренд: +DI>-DI, EMA21>EMA50, закрытие выше EMA50, ST не против
   if(pdi > mdi && emaF1 > emaS1 && c1 > emaS1 && (!UseHTFBias || htf >= 0)) {
      if(l1 <= emaF1 && c1 > emaF1) return +1;   // откат к EMA21 и возврат вверх
   }
   // нисходящий тренд
   if(mdi > pdi && emaF1 < emaS1 && c1 < emaS1 && (!UseHTFBias || htf <= 0)) {
      if(h1 >= emaF1 && c1 < emaF1) return -1;   // откат к EMA21 и возврат вниз
   }
   return 0;
}

// Боковик: фейдим экстремумы канала Donchian при подтверждении RSI.
int RangeSignal(string pair, int tf)
{
   double hh = HighestHigh(pair, tf, RangeLookback, 1);
   double ll = LowestLow(pair, tf, RangeLookback, 1);
   double band = hh - ll;
   if(band <= 0) return 0;

   double c1   = iClose(pair, tf, 1);
   double rsi  = iRSI(pair, tf, RangeRSIPeriod, PRICE_CLOSE, 1);
   double edge = band * RangeEdgePct;

   if(c1 <= ll + edge && rsi <= RangeRSIUnder) return +1;   // у нижней границы + перепроданность
   if(c1 >= hh - edge && rsi >= RangeRSIOver)  return -1;   // у верхней границы + перекупленность
   return 0;
}

// Смещение старшего ТФ по EMA (для согласования трендовых входов).
int HTFbias(string pair, int tf)
{
   int htf = HigherTF(tf);
   double emaF = iMA(pair, htf, TrendEMAFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaS = iMA(pair, htf, TrendEMASlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   if(emaF > emaS) return +1;
   if(emaF < emaS) return -1;
   return 0;
}

int HigherTF(int tf)
{
   if(tf == 5)  return 30;
   if(tf == 15) return 60;
   if(tf == 30) return 240;
   if(tf == 60) return 1440;
   return tf;
}

double HighestHigh(string pair, int tf, int count, int start)
{
   int idx = iHighest(pair, tf, MODE_HIGH, count, start);
   if(idx < 0) idx = start;
   return iHigh(pair, tf, idx);
}

double LowestLow(string pair, int tf, int count, int start)
{
   int idx = iLowest(pair, tf, MODE_LOW, count, start);
   if(idx < 0) idx = start;
   return iLow(pair, tf, idx);
}

// =========================================================
// LEGACY ENTRY (fallback, как в Ruby1) — старый фейд флипов SAR.
// =========================================================
int LegacySignal(string pair, int tf)
{
   bool sb = Check45BarScan(pair, tf, true);
   bool ss = Check45BarScan(pair, tf, false);
   if(sb && CheckTrigger(pair, tf, true))  return +1;
   if(ss && CheckTrigger(pair, tf, false)) return -1;
   return 0;
}

bool Check45BarScan(string pair, int tf, bool isBuy)
{
   double minHigh = 999999, maxLow = 0;
   double minSAR  = 999999, maxSAR = 0;

   for(int i = 1; i <= 45; i++) {
      double high = iHigh(pair, tf, i);
      double low  = iLow(pair, tf, i);
      double sar  = iSAR(pair, tf, 0.002, 0.2, i);

      if(high < minHigh) minHigh = high;
      if(low  > maxLow)  maxLow  = low;
      if(sar  < minSAR)  minSAR  = sar;
      if(sar  > maxSAR)  maxSAR  = sar;
   }

   if(isBuy) return (minHigh < maxSAR) && (minSAR < maxLow);
   return (maxLow > minSAR) && (maxSAR > minHigh);
}

bool CheckTrigger(string pair, int tf, bool isBuy)
{
   double green0 = iSAR(pair, tf, 0.002, 0.2, 0);
   double green1 = iSAR(pair, tf, 0.002, 0.2, 1);
   double black0 = iSAR(pair, tf, 0.005, 0.2, 0);
   double black1 = iSAR(pair, tf, 0.005, 0.2, 1);

   double high1 = iHigh(pair, tf, 1);
   double low1  = iLow(pair, tf, 1);
   double high0 = iHigh(pair, tf, 0);
   double low0  = iLow(pair, tf, 0);

   if(isBuy) {
      bool greenRule = (green1 < low1) && (high0 < green0);
      bool blackRule = (black1 < low1) && (high0 < black0);
      return ((greenRule || blackRule) && (high0 < green0));
   } else {
      bool greenRule = (green1 > high1) && (low0 > green0);
      bool blackRule = (black1 > high1) && (low0 > black0);
      return ((greenRule || blackRule) && (low0 > green0));
   }
}

//+------------------------------------------------------------------+
//| TRADE COUNTING                                                   |
//+------------------------------------------------------------------+
int CountTrades(string pair, int tf, int type)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != pair) continue;

      string comment = OrderComment();
      int pos1 = StringFind(comment, "_");
      int pos2 = StringFind(comment, "_", pos1 + 1);
      if(pos1 > 0 && pos2 > 0) {
         int orderTf   = (int)StringToInteger(StringSubstr(comment, pos1 + 1, pos2 - pos1 - 1));
         int orderType = (int)StringToInteger(StringSubstr(comment, pos2 + 1));
         if(orderTf == tf && orderType == type && OrderType() == type) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCycleStateIfNeeded();
   if(TradingLockedForDay) return;
   if(CheckAndExecuteDailyTarget()) return;

   SmartExitEngine();

   if(UseElasticTrailing) ElasticATRTrailing();

   for(int p = 0; p < ArraySize(PairsList); p++) {
      string pair = PairsList[p];
      if(MarketInfo(pair, MODE_BID) <= 0) continue;

      for(int i = 0; i < ArraySize(TF_Array); i++) {
         int tf = TF_Array[i];
         if(!IsTimeframeAllowed(pair, tf)) continue;
         if(LastTradeTime[p][i] == iTime(pair, tf, 0)) continue;

         double spreadPips = (MarketInfo(pair, MODE_ASK) - MarketInfo(pair, MODE_BID)) / MarketInfo(pair, MODE_POINT);
         if(MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) spreadPips /= 10;
         if(spreadPips > MaxSpreadPips) continue;

         int sig;
         if(UseAdaptiveEntry) {
            // adaptive-сигнал по закрытым барам -> считаем раз на новый бар
            datetime barT = iTime(pair, tf, 0);
            if(SignalBarTime[p][i] != barT) {
               SignalCache[p][i]   = GetAdaptiveSignal(pair, tf);
               SignalBarTime[p][i] = barT;
            }
            sig = SignalCache[p][i];
         } else {
            sig = LegacySignal(pair, tf);   // старый вход зависит от формирующегося бара
         }

         if(sig == 0) continue;

         if(sig > 0) {
            int buys  = CountTrades(pair, tf, OP_BUY);
            int sells = CountTrades(pair, tf, OP_SELL);
            if(buys == 0 || (sells > 0 && buys < MaxHedgeOrders))
               ExecuteTrade(pair, tf, OP_BUY, p, i);
         }
         else {
            int buys  = CountTrades(pair, tf, OP_BUY);
            int sells = CountTrades(pair, tf, OP_SELL);
            if(sells == 0 || (buys > 0 && sells < MaxHedgeOrders))
               ExecuteTrade(pair, tf, OP_SELL, p, i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXECUTION                                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(string pair, int tf, int type, int pIndex, int tfIndex)
{
   double pip = PipOf(pair);

   // --- стоп: ATR-адаптивный (универсально по парам) с пунктовыми ограничителями ---
   double stopPips;
   if(UseATRStops) {
      double atr = iATR(pair, tf, ATR_Period, 1);
      stopPips = (atr / pip) * StopATRMult;
      stopPips = MathMax(MinStopPips, MathMin(MaxStopPips, stopPips));
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
      Print("Opened ", type == OP_BUY ? "BUY" : "SELL", " | ", pair, " TF:", tf, " Lot:", lot);
   }
}

// =========================================================
// *** ADAPTIVE CONVICTION EXIT (ACE) ENGINE ***  (stateless, как в Ruby1)
// =========================================================
void SmartExitEngine()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair   = OrderSymbol();
      int    type   = OrderType();
      int    ticket = OrderTicket();
      double entry  = OrderOpenPrice();
      double sl     = OrderStopLoss();
      double tp     = OrderTakeProfit();
      int    tf     = GetOrderTF(OrderComment());

      double pip = PipOf(pair);
      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);
      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      // R (в пунктах) восстанавливаем из персистентного TP -> stateless, restart-safe.
      double Rpips = OrderRiskPips(entry, tp, pip);

      // --- [5] Hard Emergency Exit (в долях R) ---
      if(currentPnlPips <= -EmergencyAtR * Rpips) {
         CloseOrderByTicket(ticket, "EMERGENCY_" + DoubleToString(currentPnlPips, 1) + "pips");
         continue;
      }

      // --- Частичная фиксация на +PartialAtR*R: фаза читается из SL ---
      if(UsePartialClose && !PartialDone(type, entry, sl) &&
         currentPnlPips >= PartialAtR * Rpips) {
         DoPartialAndBE(ticket);
         continue;
      }

      if(currentPnlPips > 0) {
         if(currentPnlPips >= TrailingActivationPips) {
            double S = ConvictionScore(pair, tf, type);
            if(S <= -ConvictionExitProfit) {
               CloseOrderByTicket(ticket, "CONV_FLIP_PROFIT_" + DoubleToString(S,2));
               continue;
            }
         }
      }
      else {
         if(UseVolatilityPulse && IsMarketDead(pair, tf)) {
            CloseOrderByTicket(ticket, "VOLATILITY_DEAD");
            continue;
         }
         // умные выходы в минусе — от -LossActivationR*R
         if(currentPnlPips <= -LossActivationR * Rpips) {
            if(SARBetrayalDetected(pair, tf, type, pip)) {
               CloseOrderByTicket(ticket, "SAR_BETRAYAL");
               continue;
            }
            double S = ConvictionScore(pair, tf, type);
            if(S <= -ConvictionExitLoss) {
               CloseOrderByTicket(ticket, "CONV_AGAINST_" + DoubleToString(S,2));
               continue;
            }
            if(currentPnlPips > -MomDeathMaxR * Rpips && MomentumDying(pair, tf, type)) {
               CloseOrderByTicket(ticket, "MOMENTUM_DEATH");
               continue;
            }
         }
      }
   }
}

// R (риск в пунктах) из TP: TP = entry +/- R*InitialTP_RR. TP не двигается ->
// значение восстанавливается в любой момент, без памяти и переживая рестарт.
double OrderRiskPips(double entry, double tp, double pip)
{
   if(tp <= 0 || InitialTP_RR <= 0 || pip <= 0)
      return (UseATRStops ? MinStopPips : InitialStopPips);   // безопасный fallback
   return (MathAbs(tp - entry) / pip) / InitialTP_RR;
}

bool PartialDone(int type, double entry, double sl)
{
   if(!UsePartialClose) return true;
   if(sl == 0) return false;
   return (type == OP_BUY) ? (sl >= entry) : (sl <= entry);
}

double ConvictionScore(string pair, int tf, int type)
{
   double price = iClose(pair, tf, 1);

   double sar  = iSAR(pair, tf, 0.002, 0.2, 1);
   double sSAR = (type == OP_BUY) ? ((sar < price) ? 1.0 : -1.0)
                                  : ((sar > price) ? 1.0 : -1.0);

   double mNow  = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, 1) -
                  iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double mPrev = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, 2) -
                  iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double slope = mNow - mPrev;
   double sMom  = (type == OP_BUY) ? ((slope > 0) ? 1.0 : -1.0)
                                   : ((slope < 0) ? 1.0 : -1.0);

   double sTrend = GetTrendStrength(pair, tf, type) * 2.0 - 1.0;

   return (sSAR + sMom + sTrend) / 3.0;
}

void DoPartialAndBE(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return;

   string pair  = OrderSymbol();
   int    type  = OrderType();
   double entry = OrderOpenPrice();
   double lots  = OrderLots();
   double tp    = OrderTakeProfit();
   double curSL = OrderStopLoss();
   int    digits = (int)MarketInfo(pair, MODE_DIGITS);
   double pip   = PipOf(pair);
   double buf   = BreakevenBufferPips * pip;

   double newSL;
   if(type == OP_BUY) {
      newSL = MathMax(curSL, entry + buf);
      newSL = NormalizeDouble(newSL, digits);
      if(newSL > curSL) OrderModify(ticket, entry, newSL, tp, 0, clrAqua);
   } else {
      double be = entry - buf;
      newSL = (curSL == 0) ? be : MathMin(curSL, be);
      newSL = NormalizeDouble(newSL, digits);
      if(curSL == 0 || newSL < curSL) OrderModify(ticket, entry, newSL, tp, 0, clrAqua);
   }

   double lotStep = MarketInfo(pair, MODE_LOTSTEP);
   double minLot  = MarketInfo(pair, MODE_MINLOT);
   if(lotStep <= 0) lotStep = 0.01;

   double closeLots = MathFloor((lots * (PartialClosePercent / 100.0)) / lotStep) * lotStep;
   closeLots = NormalizeDouble(closeLots, 2);
   if(closeLots < minLot)        return;
   if(lots - closeLots < minLot) return;

   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return;
   RefreshRates();
   double price = (type == OP_BUY) ? MarketInfo(pair, MODE_BID) : MarketInfo(pair, MODE_ASK);
   OrderClose(ticket, closeLots, price, Slippage, clrViolet);
}

//+------------------------------------------------------------------+
//| [1] SAR Betrayal Detector                                        |
//+------------------------------------------------------------------+
bool SARBetrayalDetected(string pair, int tf, int orderType, double pip)
{
   int betrayCount = 0;

   for(int bar = 1; bar <= SARBetrayalBars; bar++) {
      double sar  = iSAR(pair, tf, 0.002, 0.2, bar);
      double high = iHigh(pair, tf, bar);
      double low  = iLow(pair, tf, bar);
      double mid  = (high + low) / 2.0;

      double sarDistPips = MathAbs(sar - mid) / pip;
      if(sarDistPips < SARBetrayalMinPips) continue;

      if(orderType == OP_BUY  && sar > high) betrayCount++;
      if(orderType == OP_SELL && sar < low)  betrayCount++;
   }

   return (betrayCount >= 2);
}

//+------------------------------------------------------------------+
//| [2] Momentum Death Signal                                        |
//+------------------------------------------------------------------+
bool MomentumDying(string pair, int tf, int orderType)
{
   int deathCount = 0;

   for(int bar = 1; bar <= MomDeathBars; bar++) {
      double fastEMA_now  = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, bar);
      double slowEMA_now  = iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, bar);
      double fastEMA_prev = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, bar + 1);
      double slowEMA_prev = iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, bar + 1);

      double momNow  = fastEMA_now  - slowEMA_now;
      double momPrev = fastEMA_prev - slowEMA_prev;

      if(orderType == OP_BUY  && momNow < momPrev) deathCount++;
      if(orderType == OP_SELL && momNow > momPrev) deathCount++;
   }

   int need = MathMin(MomDeathMinCount, MomDeathBars);
   return (deathCount >= need);
}

//+------------------------------------------------------------------+
//| [4] Volatility Pulse                                             |
//+------------------------------------------------------------------+
bool IsMarketDead(string pair, int tf)
{
   int deadCount = 0;
   double pip = PipOf(pair);

   for(int bar = 1; bar <= VolatilityDeadBarsMin; bar++) {
      double atrPips = iATR(pair, tf, ATR_Period, bar) / pip;
      if(atrPips < VolatilityDeadPips) deadCount++;
   }

   int need = MathMin(VolatilityDeadMinCount, VolatilityDeadBarsMin);
   return (deadCount >= need);
}

// =========================================================
// *** ELASTIC ATR TRAILING STOP ***  (как в Ruby1)
// =========================================================
void ElasticATRTrailing()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair      = OrderSymbol();
      int    type      = OrderType();
      double entry     = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentTP = OrderTakeProfit();
      int    orderTF   = GetOrderTF(OrderComment());

      double pip = PipOf(pair);
      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;
      if(currentPnlPips < TrailingActivationPips) continue;

      double atrNow = iATR(pair, orderTF, ATR_Period, 1);
      if(atrNow <= 0) continue;

      double trendStrength = GetTrendStrength(pair, orderTF, type);
      double dynamicMult   = ATR_MultiplierSlow + trendStrength * (ATR_MultiplierFast - ATR_MultiplierSlow);
      double trailingDistance = atrNow * dynamicMult;

      bool   beforePartial = (UsePartialClose && !PartialDone(type, entry, currentSL));
      double eps = pip;

      if(type == OP_BUY) {
         double newSL = bid - trailingDistance;
         if(beforePartial) newSL = MathMin(newSL, entry - eps);
         else              newSL = MathMax(newSL, entry);
         newSL = NormalizeDouble(newSL, (int)MarketInfo(pair, MODE_DIGITS));
         if(newSL > currentSL && newSL < bid)
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
      }
      else if(type == OP_SELL) {
         double newSL = ask + trailingDistance;
         if(beforePartial) newSL = MathMax(newSL, entry + eps);
         else              newSL = MathMin(newSL, entry);
         newSL = NormalizeDouble(newSL, (int)MarketInfo(pair, MODE_DIGITS));
         if((newSL < currentSL || currentSL == 0) && newSL > ask)
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
      }
   }
}

//+------------------------------------------------------------------+
//| Оценка силы тренда [0.0 .. 1.0]                                  |
//+------------------------------------------------------------------+
double GetTrendStrength(string pair, int tf, int orderType)
{
   int alignedBars = 0;

   for(int bar = 1; bar <= TrendStrengthBars; bar++) {
      double open  = iOpen(pair, tf, bar);
      double close = iClose(pair, tf, bar);

      if(orderType == OP_BUY  && close > open) alignedBars++;
      if(orderType == OP_SELL && close < open) alignedBars++;
   }

   return (double)alignedBars / (double)TrendStrengthBars;
}

//+------------------------------------------------------------------+

