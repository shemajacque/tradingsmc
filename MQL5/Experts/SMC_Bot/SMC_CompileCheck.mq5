//+------------------------------------------------------------------+
//| Compile-check harness for SMC include files (not a trading EA).   |
//+------------------------------------------------------------------+
#property strict
#include <SMC/SMC_Types.mqh>
#include <SMC/SMC_Time.mqh>
#include <SMC/SMC_Structure.mqh>
#include <SMC/SMC_POI.mqh>
#include <SMC/SMC_Bias.mqh>
#include <SMC/SMC_Setups.mqh>
#include <SMC/SMC_Logger.mqh>
#include <SMC/SMC_Risk.mqh>
#include <SMC/SMC_Trade.mqh>
#include <SMC/SMC_CloseLevel.mqh>
#include <SMC/SMC_TopDown.mqh>
#include <SMC/MSNR_Levels.mqh>
#include <SMC/MSNR_Storyline.mqh>
#include <SMC/MSNR_SetupM.mqh>

int OnInit()
{
   CStructure s;
   CPOIEngine poi;
   CBiasEngine bias;
   poi.Init(&s, PERIOD_M15, 0.5, false, 0.6, 0.1);
   bias.Init(NULL, &s, &s, &s, NULL, NULL, NULL, NULL, false, false, 0.0);
   return INIT_SUCCEEDED;
}
void OnTick() {}
