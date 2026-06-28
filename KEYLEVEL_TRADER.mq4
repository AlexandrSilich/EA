//+------------------------------------------------------------------+
//|                                           KEYLEVEL_TRADER.mq4    |
//|                        Multi-Timeframe Reverse Harmonic SAR EA   |
//|                        V1.3: CircleStartEquity per-round target  |
//+------------------------------------------------------------------+
#property copyright "KEYLEVEL TRADER Strategy"
#property link      ""
#property version   "1.30"
#property strict

// --- INPUT PARAMETERS ---
// Risk & Equity Management
extern bool   UseDailyEquityTarget     = true;
extern double DailyProfitTargetPercent = 5.0;
extern int    MaxCountCircles          = 2;    // Max daily circles (basket closes by equity target)

// Trade Management
extern int    MagicNumber         = 20240625;
extern int    Slippage            = 3;
extern double MaxSpreadPips       = 3.0;
extern int    MaxHedgeOrders      = 1;        // 0 = no hedging, 1 = max one counter-order per pair/TF

// --- GLOBAL VARIABLES ---
string PairsList[] = {
   "EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD",
   "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD",
   "EURAUD","EURNZD","GBPCAD","GBPCHF","NZDCAD","CADJPY","CADCHF",
   "AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD"
};

int TF_Array[] = {60, 30, 15, 5};
datetime LastTradeTime[27][4];

datetime TradingDayStart   = 0;
int      DailyTargetHits   = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity = 0;   // Base equity for current circle target

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayInitialize(LastTradeTime, 0);
   TradingDayStart    = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   DailyTargetHits    = 0;
   TradingLockedForDay = false;
   CircleStartEquity  = AccountBalance();
   Print("KEYLEVEL_TRADER 1.3 Initialized. CircleStartEquity: ", CircleStartEquity);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Reset state on new trading day                                   |
//+------------------------------------------------------------------+
void ResetDailyCycleStateIfNeeded()
{
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(TradingDayStart != todayStart) {
      TradingDayStart     = todayStart;
      DailyTargetHits     = 0;
      TradingLockedForDay = false;
      CircleStartEquity   = AccountBalance();
      Print("New trading day. Counters reset. CircleStartEquity: ", CircleStartEquity);
   }
}

//+------------------------------------------------------------------+
//| DAILY EQUITY TARGET LOGIC                                        |
//+------------------------------------------------------------------+
bool CheckAndExecuteDailyTarget()
{
   if(!UseDailyEquityTarget) return false;
   if(TradingLockedForDay) return true;
   if(CircleStartEquity <= 0) return false;

   double targetEquity  = CircleStartEquity * (1.0 + (DailyProfitTargetPercent / 100.0));
   double currentEquity = AccountEquity();

   if(currentEquity >= targetEquity) {
      Print("!!! CIRCLE TARGET REACHED !!! Equity: ", currentEquity,
            " >= Target: ", targetEquity,
            " (CircleBase: ", CircleStartEquity, ")");
      CloseAllOpenTrades();
      DailyTargetHits++;
      Print("Daily circles completed: ", DailyTargetHits, " / ", MaxCountCircles);

      if(DailyTargetHits >= MaxCountCircles) {
         TradingLockedForDay = true;
         Print("Trading locked until next trading day.");
      } else {
         // Start next circle from current balance
         CircleStartEquity = AccountBalance();
         Print("New circle started. CircleStartEquity: ", CircleStartEquity);
      }
      return true;
   }
   return false;
}

void CloseAllOpenTrades()
{
   int maxRetries = 3;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      bool closed = false;
      for(int attempt = 1; attempt <= maxRetries; attempt++) {
         RefreshRates(); // актуализируем цены перед каждой попыткой

         double closePrice = (OrderType() == OP_BUY)
            ? MarketInfo(OrderSymbol(), MODE_BID)
            : MarketInfo(OrderSymbol(), MODE_ASK);

         if(OrderClose(OrderTicket(), OrderLots(), closePrice, Slippage, clrGreen)) {
            closed = true;
            break;
         }

         int err = GetLastError();
         Print("Close attempt ", attempt, " failed. Ticket: ", OrderTicket(),
               " Error: ", err);

         // Пауза перед retry (только для retriable ошибок)
         if(err == ERR_OFF_QUOTES || err == ERR_REQUOTE || err == ERR_PRICE_CHANGED)
            Sleep(500);
         else
            break; // фатальная ошибка — не повторяем
      }

      if(!closed)
         Print("WARNING: Failed to close ticket ", OrderTicket(), " after ", maxRetries, " attempts.");
   }
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
//| 45-BAR SCAN LOGIC                                                |
//+------------------------------------------------------------------+
bool Check45BarScan(string pair, int tf, bool isBuy)
{
   double minHigh = 999999, maxLow = 0;
   double minSAR = 999999, maxSAR = 0;

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
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCycleStateIfNeeded();
   if(TradingLockedForDay) return;
   if(CheckAndExecuteDailyTarget()) return;

   ManageOpenTrades();

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

   string comment = StringFormat("KL_%d_%d", tf, type);
   int ticket = OrderSend(pair, type, lot, price, Slippage, sl, tp, comment, MagicNumber, 0,
                          type == OP_BUY ? clrBlue : clrRed);

   if(ticket > 0) {
      LastTradeTime[pIndex][tfIndex] = iTime(pair, tf, 0);
      Print("Opened ", type == OP_BUY ? "BUY" : "SELL", " on ", pair, " TF: ", tf);
   }
}

//+------------------------------------------------------------------+
//| EXIT LOGIC (1:1 BE, 1:2 lock +20 pips, 1:3 TP)                  |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair      = OrderSymbol();
      double entry     = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentTP = OrderTakeProfit();

      double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                   MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);
      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      if(OrderType() == OP_BUY) {
         double price_1to1 = entry + (60 * pip);
         double price_1to2 = entry + (120 * pip);
         double sl_1to2    = entry + (20 * pip);

         if(bid >= price_1to2 && (currentSL < sl_1to2 || currentSL == 0))
            OrderModify(OrderTicket(), entry, sl_1to2, currentTP, 0, clrGreen);
         else if(bid >= price_1to1 && (currentSL < entry || currentSL == 0))
            OrderModify(OrderTicket(), entry, entry, currentTP, 0, clrGreen);
      }
      else if(OrderType() == OP_SELL) {
         double price_1to1 = entry - (60 * pip);
         double price_1to2 = entry - (120 * pip);
         double sl_1to2    = entry - (20 * pip);

         if(ask <= price_1to2 && (currentSL > sl_1to2 || currentSL == 0))
            OrderModify(OrderTicket(), entry, sl_1to2, currentTP, 0, clrRed);
         else if(ask <= price_1to1 && (currentSL > entry || currentSL == 0))
            OrderModify(OrderTicket(), entry, entry, currentTP, 0, clrRed);
      }
   }
}
//+------------------------------------------------------------------+
