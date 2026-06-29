//+------------------------------------------------------------------+
//|                                      KEYLEVEL_TRADER_New1.mq4   |
//|          Smart Exit Engine: SAR Betrayal + Momentum Death        |
//|          + Elastic ATR Trailing + Volatility Pulse Filter        |
//|          Based on KEYLEVEL_TRADER V1.3                           |
//|          NEW: Intelligent early exit, no classic SL waiting      |
//+------------------------------------------------------------------+
#property copyright "KEYLEVEL TRADER New1 Strategy"
#property link      ""
#property version   "2.00"
#property strict

// =========================================================
// INPUT PARAMETERS
// =========================================================

// --- Risk & Equity Management ---
extern bool   UseDailyEquityTarget     = true;
extern double DailyProfitTargetPercent = 5.0;
extern int    MaxCountCircles          = 2;

// --- Trade Management ---
extern int    MagicNumber      = 20260629;
extern int    Slippage         = 3;
extern double MaxSpreadPips    = 3.0;
extern int    MaxHedgeOrders   = 1;

// =========================================================
// === SMART EXIT ENGINE PARAMETERS ===
// =========================================================

// --- [1] SAR Betrayal Score ---
// Если SAR перевернулся против сделки N баров подряд — ранний выход
extern int    SARBetrayalBars         = 3;    // сколько баров SAR должен "предать" для выхода
extern double SARBetrayalMinPips      = 5.0;  // минимальное расстояние SAR от цены (фильтр шума)

// --- [2] Momentum Death Signal ---
// Измеряем скорость изменения цены через разницу EMA(fast) - EMA(slow)
// Если моментум разворачивается против нас ДО достижения даже 0.5*SL — выходим
extern int    MomFastEMA              = 5;    // быстрая EMA для моментума
extern int    MomSlowEMA              = 13;   // медленная EMA для моментума
extern int    MomDeathBars            = 4;    // сколько баров моментум должен умирать подряд
extern double MomDeathMinPipsLoss     = 8.0;  // не выходим если убыток < этого значения (не реагируем на шум)
extern double MomDeathMaxPipsLoss     = 35.0; // выходим принудительно если убыток > этого значения

// --- [3] Elastic ATR Trailing Stop ---
extern bool   UseElasticTrailing      = true;
extern int    ATR_Period              = 14;
extern double ATR_MultiplierFast      = 1.2;  // мультипликатор в сильном тренде (широкий трейлинг)
extern double ATR_MultiplierSlow      = 0.7;  // мультипликатор при замедлении (сжимаем трейлинг)
extern int    TrendStrengthBars       = 8;    // сколько баров смотрим для оценки силы тренда
extern double TrailingActivationPips  = 20.0; // активируем трейлинг только после этого профита в пипсах

// --- [4] Volatility Pulse Filter ---
// Если ATR упал ниже порога — рынок "умер", выходим из убыточных позиций быстрее
extern bool   UseVolatilityPulse      = true;
extern double VolatilityDeadZoneATR   = 0.0003; // если ATR(14) < этого — рынок "мертв" (для EURUSD ~0.3 pips)
extern int    VolatilityDeadBarsMin   = 5;       // сколько баров рынок должен быть мертв подряд

// --- [5] Hard Emergency Exit ---
// Если убыток превысил этот порог (в пипсах) — немедленный выход без ожидания SL
extern double EmergencyExitPips       = 45.0;   // аварийный выход до SL (SL остается как страховка)

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

datetime TradingDayStart    = 0;
int      DailyTargetHits    = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayInitialize(LastTradeTime, 0);
   TradingDayStart     = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   DailyTargetHits     = 0;
   TradingLockedForDay = false;
   CircleStartEquity   = AccountBalance();
   Print("KEYLEVEL_TRADER_New1 v2.0 Initialized. SmartExit Engine ACTIVE. CircleEquity: ", CircleStartEquity);
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

// Закрыть конкретный ордер с сообщением причины
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

//+------------------------------------------------------------------+
//| 45-BAR SCAN                                                      |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| TRIGGER LOGIC                                                    |
//+------------------------------------------------------------------+
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

   // SmartExit Engine — проверяем ВСЕ открытые ордера
   SmartExitEngine();

   // Elastic ATR Trailing
   if(UseElasticTrailing) ElasticATRTrailing();

   // Открываем новые ордера
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

         bool scanBuy  = Check45BarScan(pair, tf, true);
         bool scanSell = Check45BarScan(pair, tf, false);
         if(!scanBuy && !scanSell) continue;

         bool triggerBuy  = CheckTrigger(pair, tf, true);
         bool triggerSell = CheckTrigger(pair, tf, false);

         if(scanBuy && triggerBuy) {
            int buys  = CountTrades(pair, tf, OP_BUY);
            int sells = CountTrades(pair, tf, OP_SELL);
            if(buys == 0 || (sells > 0 && buys < MaxHedgeOrders))
               ExecuteTrade(pair, tf, OP_BUY, p, i);
         }

         if(scanSell && triggerSell) {
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
   double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

   double sl, tp, price, riskDistance;

   if(type == OP_BUY) {
      price        = MarketInfo(pair, MODE_ASK);
      sl           = price - (60 * pip);
      riskDistance = price - sl;
      tp           = price + (180 * pip);
   } else {
      price        = MarketInfo(pair, MODE_BID);
      sl           = price + (60 * pip);
      riskDistance = sl - price;
      tp           = price - (180 * pip);
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
// *** SMART EXIT ENGINE ***
// Логика: несколько независимых сигналов выхода.
// Достаточно ОДНОГО сработавшего — ордер закрывается.
// =========================================================
void SmartExitEngine()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair  = OrderSymbol();
      int    type  = OrderType();
      int    ticket = OrderTicket();
      double entry = OrderOpenPrice();

      double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                   MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      // Текущий P&L в пипсах
      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      // --- [5] Emergency Exit (первым — самый важный) ---
      if(currentPnlPips <= -EmergencyExitPips) {
         CloseOrderByTicket(ticket, "EMERGENCY_" + DoubleToString(currentPnlPips, 1) + "pips");
         continue;
      }

      // --- [4] Volatility Pulse Filter ---
      if(UseVolatilityPulse && currentPnlPips < 0) {
         if(IsMarketDead(pair, PERIOD_M15)) {
            CloseOrderByTicket(ticket, "VOLATILITY_DEAD");
            continue;
         }
      }

      // --- [1] SAR Betrayal Score ---
      if(currentPnlPips <= -MomDeathMinPipsLoss) { // только если уже в минусе
         if(SARBetrayalDetected(pair, PERIOD_M15, type, pip)) {
            CloseOrderByTicket(ticket, "SAR_BETRAYAL");
            continue;
         }
      }

      // --- [2] Momentum Death Signal ---
      if(currentPnlPips <= -MomDeathMinPipsLoss && currentPnlPips > -MomDeathMaxPipsLoss) {
         if(MomentumDying(pair, PERIOD_M15, type)) {
            CloseOrderByTicket(ticket, "MOMENTUM_DEATH");
            continue;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [1] SAR Betrayal Detector                                        |
//| SAR "предает" направление N баров подряд                         |
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
      if(sarDistPips < SARBetrayalMinPips) continue; // слишком близко — шум

      if(orderType == OP_BUY && sar > high) betrayCount++;   // SAR над ценой при BUY — предательство
      if(orderType == OP_SELL && sar < low)  betrayCount++;  // SAR под ценой при SELL — предательство
   }

   return (betrayCount >= SARBetrayalBars);
}

//+------------------------------------------------------------------+
//| [2] Momentum Death Signal                                        |
//| EMA-momentum разворачивается против нас N баров подряд           |
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

      // Для BUY: моментум должен расти. Если падает — "умирает"
      if(orderType == OP_BUY  && momNow < momPrev) deathCount++;
      // Для SELL: моментум должен падать. Если растет — "умирает"
      if(orderType == OP_SELL && momNow > momPrev) deathCount++;
   }

   return (deathCount >= MomDeathBars);
}

//+------------------------------------------------------------------+
//| [4] Volatility Pulse: проверка "мертвого рынка"                  |
//+------------------------------------------------------------------+
bool IsMarketDead(string pair, int tf)
{
   int deadCount = 0;

   for(int bar = 1; bar <= VolatilityDeadBarsMin; bar++) {
      double atr = iATR(pair, tf, ATR_Period, bar);
      if(atr < VolatilityDeadZoneATR) deadCount++;
   }

   return (deadCount >= VolatilityDeadBarsMin);
}

// =========================================================
// *** ELASTIC ATR TRAILING STOP ***
// Трейлинг динамически сжимается при замедлении тренда
// и расширяется при сильном движении
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

      double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                   MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      // Активируем трейлинг только после достижения порога профита
      if(currentPnlPips < TrailingActivationPips) continue;

      // Получаем ATR текущего бара и считаем силу тренда
      double atrNow = iATR(pair, PERIOD_M15, ATR_Period, 1);
      if(atrNow <= 0) continue;

      double trendStrength = GetTrendStrength(pair, PERIOD_M15, type);

      // Выбираем мультипликатор динамически
      // trendStrength [0..1]: 1 = сильный тренд, 0 = слабый/боковик
      double dynamicMult = ATR_MultiplierSlow + trendStrength * (ATR_MultiplierFast - ATR_MultiplierSlow);

      double trailingDistance = atrNow * dynamicMult;

      if(type == OP_BUY) {
         double newSL = NormalizeDouble(bid - trailingDistance, (int)MarketInfo(pair, MODE_DIGITS));
         // SL только вверх (никогда не опускаем)
         if(newSL > currentSL && newSL < bid) {
            // Не опускаем ниже entry (защита капитала)
            if(newSL < entry) newSL = entry;
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
         }
      }
      else if(type == OP_SELL) {
         double newSL = NormalizeDouble(ask + trailingDistance, (int)MarketInfo(pair, MODE_DIGITS));
         // SL только вниз (никогда не поднимаем)
         if((newSL < currentSL || currentSL == 0) && newSL > ask) {
            if(newSL > entry) newSL = entry;
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Оценка силы тренда [0.0 .. 1.0]                                  |
//| Считаем долю баров которые двигались в направлении ордера        |
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

   return (double)alignedBars / (double)TrendStrengthBars; // от 0 до 1
}

//+------------------------------------------------------------------+
