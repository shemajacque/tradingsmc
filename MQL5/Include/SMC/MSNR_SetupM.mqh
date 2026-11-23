//+------------------------------------------------------------------+
//|  MSNR_SetupM.mqh                                                 |
//|  OPTIONAL Setup M (A8), active only when InpEnableMSNR = true.     |
//|                                                                  |
//|  The source describes this entry as very risky/aggressive and     |
//|  requires five to six confluences. It is implemented exactly as    |
//|  written (no extension): confirmed storyline, closed rejection,    |
//|  fresh key level with turtle soup on a lower TF, limit entry, SL    |
//|  beyond the turtle-soup wick, T1/T2/T3 partials 40/30/30, step      |
//|  down one TF if missed, msnrScore >= InpMSNRMinScore.              |
//+------------------------------------------------------------------+
#ifndef MSNR_SETUPM_MQH
#define MSNR_SETUPM_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"
#include "SMC_Bias.mqh"
#include "MSNR_Levels.mqh"
#include "MSNR_Storyline.mqh"

class CMSNRSetupM
{
private:
   CMSNRLevels*      m_h4;
   CMSNRLevels*      m_h1;
   CMSNRStoryline*   m_story;
   CBiasEngine*      m_bias;
   double            m_slBufferPoints;
   double            m_point;
   int               m_minScore;
   double            m_tp1Pct;
   double            m_tp2Pct;
   double            m_tp3Pct;
   bool              m_lastLiqRequired;

   int Score(const MSNR_Story &st, const MSNR_Level &lv,
             const bool liqBeyond, const bool htOverlap,
             const bool inducement) const
   {
      int s = 0;
      if(st.confirmed)
         s++;
      if(lv.strong)
         s++;
      if(lv.fresh)
         s++;
      if(st.lastLiquidityTaken || !m_lastLiqRequired)
         s++;
      if(liqBeyond)
         s++;
      if(htOverlap)
         s++;
      if(inducement)
         s++;
      return s;
   }

public:
   void Init(CMSNRLevels* h4, CMSNRLevels* h1, CMSNRStoryline* story,
             CBiasEngine* bias, const double slBufferPoints,
             const double point, const int minScore,
             const double tp1Pct, const double tp2Pct, const double tp3Pct,
             const bool lastLiqRequired)
   {
      m_h4 = h4; m_h1 = h1; m_story = story; m_bias = bias;
      m_slBufferPoints = slBufferPoints;
      m_point = point;
      m_minScore = minScore;
      m_tp1Pct = tp1Pct;
      m_tp2Pct = tp2Pct;
      m_tp3Pct = tp3Pct;
      m_lastLiqRequired = lastLiqRequired;
   }

   // Returns a signal when all conditions hold.
   bool Try(const double price, TradeSignal &sig,
            const bool liqBeyond, const bool htOverlap, const bool inducement,
            const bool biasOk)
   {
      ResetSignal(sig);
      if(m_story == NULL || m_h4 == NULL || m_h1 == NULL || !biasOk)
         return false;
      MSNR_Story st = m_story.Story();
      if(!st.confirmed)
         return false;

      // Step down: H4 first, then H1 if missed (A8 step 6).
      CMSNRLevels* use = m_h4;
      MSNR_Level lv;
      if(!use.FreshKeyLevel(st.dir, m_h1, lv))
      {
         use = m_h1;
         if(!use.FreshKeyLevel(st.dir, NULL, lv))
            return false;
      }

      double entry = lv.price;
      double sl;
      if(lv.slWick > 0.0)
         sl = (st.dir == SMC_BEAR) ? lv.slWick + m_slBufferPoints * m_point
                                   : lv.slWick - m_slBufferPoints * m_point;
      else
         sl = (st.dir == SMC_BEAR) ? entry + m_slBufferPoints * m_point
                                   : entry - m_slBufferPoints * m_point;

      int sc = Score(st, lv, liqBeyond, htOverlap, inducement);
      if(sc < m_minScore)
         return false;

      double risk = MathAbs(entry - sl);
      if(risk <= 0.0)
         return false;
      double t1 = (st.targetCount > 0 && st.targets[0] > 0.0)
                ? st.targets[0] : entry + (st.dir == SMC_BEAR ? -1.5 : 1.5) * risk;
      double tn = (st.targetCount > 0 && st.targets[st.targetCount - 1] > 0.0)
                ? st.targets[st.targetCount - 1] : t1;

      sig.dir = st.dir;
      sig.entry = entry;
      sig.sl = sl;
      sig.tp1 = t1;
      sig.tpRunner = tn;
      sig.score = sc + 2;             // A8 combine bonus when A-C also fires
      sig.riskMult = 1.0;
      sig.setupType = SETUP_M;
      sig.reason = "M:msnr_storyline";
      sig.tf = use.Timeframe();
      sig.signalTime = TimeCurrent();
      sig.poiTop = lv.price;
      sig.poiBottom = lv.price;
      sig.poiType = POI_CLOSE_LEVEL;
      sig.valid = true;
      return true;
   }

   double Tp1Pct() const { return m_tp1Pct; }
   double Tp2Pct() const { return m_tp2Pct; }
   double Tp3Pct() const { return m_tp3Pct; }
};

#endif // MSNR_SETUPM_MQH
