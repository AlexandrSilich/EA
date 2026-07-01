//+------------------------------------------------------------------+
//|                                          HedgeFund_Trader.mq4    |
//|                  Multi-Timeframe Compounding Parabolic SAR EA    |
//|                  V1.0: Hierarchical Entries, Reset & Resume      |
//+------------------------------------------------------------------+
#property copyright "HedgeFund Trader Strategy"
#property link      ""
#property version   "1.00"
#property strict


// --- INPUT PARAMETERS ---
extern int    MagicNumber         = 20240630; 
extern int    Slippage            = 3;
extern double MaxSpreadPips       = 3.0;      


// Equity Growth & Reset Logic
extern bool   UseDailyReset       = true;
extern double DailyResetPercent   = 1.0;      // 1.0 means 1% growth triggers a reset


// --- GLOBAL VARIABLES ---
string PairsList[] = {
   "EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD",
   "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD",
   "EURAUD","EURNZD","GBPCAD","GBPCHF","NZDCAD","CADJPY","CADCHF",
   "AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD" 
};


// All 5 timeframes
int TF_Array[] = {60, 30, 15, 5, 1}; 


// Tracks the baseline balance for the 1% reset calculation
double LastResetBalance;


//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize the reset baseline to the current starting balance
   LastResetBalance = AccountBalance();
   Print("HedgeFund_Trader Initialized. Baseline Balance: ", LastResetBalance);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) {}


//+------------------------------------------------------------------+
//| EQUITY RESET & RESUME LOGIC                                      |
//+------------------------------------------------------------------+
void CheckAndExecuteReset()
{
   if(!UseDailyReset) return;
   
   double targetEquity = LastResetBalance * (1.0 + (DailyResetPercent / 100.0));
   double currentEquity = AccountEquity(); 
   
   // If equity exceeds the 1% target
   if(currentEquity >= targetEquity) {
      Print("!!! 1% TARGET REACHED !!! Equity: ", currentEquity, " >= Target: ", targetEquity);
      CloseAllOpenTrades();
      
      // RESET: Update the baseline to the new locked-in balance and resume trading
      LastResetBalance = AccountBalance();
      Print("Baseline reset to: ", LastResetBalance, ". Resuming trading...");
   }
}


void CloseAllOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue; 
      
      if(OrderType() == OP_BUY)
         OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_BID), Slippage, clrGreen);
      else if(OrderType() == OP_SELL)
         OrderClose(OrderTicket(), OrderLots(), MarketInfo(OrderSymbol(), MODE_ASK), Slippage, clrGreen);
   }
}


//+------------------------------------------------------------------+
//| HIERARCHICAL ENTRY RULES (KEY NOTE 1)                            |
//+------------------------------------------------------------------+
bool HasHigherTimeframePosition(string pair, int tf)
{
   if(tf == 60 || tf == 30 || tf == 15) return true; // H1, M30, M15 can trade freely
   
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != pair) continue;
      
      // Extract TF from comment
      string comment = OrderComment();
      int pos1 = StringFind(comment, "_");
      int pos2 = StringFind(comment, "_", pos1 + 1);
      if(pos1 > 0 && pos2 > 0) {
         int orderTf = (int)StringToInteger(StringSubstr(comment, pos1 + 1, pos2 - pos1 - 1));
         
         // M5 requires H1, M30, or M15
         if(tf == 5 && (orderTf == 60 || orderTf == 30 || orderTf == 15)) return true;
         // M1 requires H1, M30, M15, or M5
         if(tf == 1 && (orderTf == 60 || orderTf == 30 || orderTf == 15 || orderTf == 5)) return true;
      }
   }
   return false;
}


//+------------------------------------------------------------------+
//| 45-BAR SCAN LOGIC (OPTION C)                                     |
//+------------------------------------------------------------------+
bool Check45BarScan(string pair, int tf, bool isBuy)
{
   double minHigh = 999999, maxLow = 0;
   double minSAR = 999999, maxSAR = 0;
   
   for(int i = 1; i <= 45; i++) {
      double high = iHigh(pair, tf, i);
      double low = iLow(pair, tf, i);
      double sar = iSAR(pair, tf, 0.005, 0.2, i); // Black SAR
      
      if(high < minHigh) minHigh = high;
      if(low > maxLow) maxLow = low;
      if(sar < minSAR) minSAR = sar;
      if(sar > maxSAR) maxSAR = sar;
   }
   
   if(isBuy) {
      // BUY Inverse Scan: Any High < Any SAR AND Any SAR < Any Low
      return (minHigh < maxSAR) && (minSAR < maxLow);
   } else {
      // SELL Scan: Any Low > Any SAR AND Any SAR > Any High
      return (maxLow > minSAR) && (maxSAR > minHigh);
   }
}


//+------------------------------------------------------------------+
//| TRIGGER LOGIC                                                    |
//+------------------------------------------------------------------+
bool CheckTrigger(string pair, int tf, bool isBuy)
{
   double green0 = iSAR(pair, tf, 0.002, 0.2, 0);
   double black0 = iSAR(pair, tf, 0.005, 0.2, 0);
   double black1 = iSAR(pair, tf, 0.005, 0.2, 1);
   
   double high1 = iHigh(pair, tf, 1);
   double low1 = iLow(pair, tf, 1);
   double high0 = iHigh(pair, tf, 0);
   double low0 = iLow(pair, tf, 0);


   if(isBuy) {
      // BUY Inverse Trigger
      return (black1 < low1) && (high0 < black0) && (green0 < low0);
   } else {
      // SELL Trigger
      return (black1 > high1) && (low0 > black0) && (green0 > high0);
   }
}


//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Check Reset Target FIRST
   CheckAndExecuteReset();


   // 2. Signal Generation
   for(int p = 0; p < ArraySize(PairsList); p++) {
      string pair = PairsList[p];
      if(MarketInfo(pair, MODE_BID) <= 0) continue;


      for(int i = 0; i < ArraySize(TF_Array); i++) {
         int tf = TF_Array[i];
         
         // Check Hierarchical Rule (M5/M1 gatekeepers)
         if(!HasHigherTimeframePosition(pair, tf)) continue;


         // Check Spread
         double spreadPips = (MarketInfo(pair, MODE_ASK) - MarketInfo(pair, MODE_BID)) / MarketInfo(pair, MODE_POINT);
         if(MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) spreadPips /= 10;
         if(spreadPips > MaxSpreadPips) continue;


         // Check 45-Bar Scan
         bool scanBuy = Check45BarScan(pair, tf, true);
         bool scanSell = Check45BarScan(pair, tf, false);
         if(!scanBuy && !scanSell) continue;


         // Check Triggers
         bool triggerBuy = CheckTrigger(pair, tf, true);
         bool triggerSell = CheckTrigger(pair, tf, false);


         // Execute Buy (Multiple orders allowed)
         if(scanBuy && triggerBuy) {
            ExecuteTrade(pair, tf, OP_BUY);
         }


         // Execute Sell (Multiple orders allowed)
         if(scanSell && triggerSell) {
            ExecuteTrade(pair, tf, OP_SELL);
         }
      }
   }
}


//+------------------------------------------------------------------+
//| EXECUTION (60 or 120 PIP SL, 1:3 TP, 1% RISK)                    |
//+------------------------------------------------------------------+
void ExecuteTrade(string pair, int tf, int type)
{
   double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ? MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);
   
   // SL Logic based on Timeframe
   double slPips = (tf == 5 || tf == 1) ? 120.0 : 60.0;
   double tpPips = slPips * 3.0; // 1:3 RR


   double sl, tp, price, riskDistance;


   if(type == OP_BUY) {
      price = MarketInfo(pair, MODE_ASK);
      sl = price - (slPips * pip);
      riskDistance = price - sl;
      tp = price + (tpPips * pip); 
   } else {
      price = MarketInfo(pair, MODE_BID);
      sl = price + (slPips * pip);
      riskDistance = sl - price;
      tp = price - (tpPips * pip); 
   }
   if(riskDistance <= 0) return;


   // 1% Risk Calculation
   double riskMoney = AccountBalance() * 0.01; 
   double tickValue = MarketInfo(pair, MODE_TICKVALUE);
   double tickSize = MarketInfo(pair, MODE_TICKSIZE);
   double lot = riskMoney / ((riskDistance / tickSize) * tickValue);
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(MarketInfo(pair, MODE_MINLOT), MathMin(MarketInfo(pair, MODE_MAXLOT), lot));


   string comment = StringFormat("HF_%d_%d", type, tf);
   int ticket = OrderSend(pair, type, lot, price, Slippage, sl, tp, comment, MagicNumber, 0, type == OP_BUY ? clrBlue : clrRed);
   
   if(ticket > 0) {
      Print("Opened ", type == OP_BUY ? "BUY" : "SELL", " on ", pair, " TF: ", tf);
   }
}
//+------------------------------------------------------------------+
