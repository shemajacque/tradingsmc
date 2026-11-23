//+------------------------------------------------------------------+
//|  MSNR_Levels.mqh                                                 |
//|  OPTIONAL module (A6), active only when InpEnableMSNR = true.     |
//|                                                                  |
//|  Key level types from the MSNR lessons:                           |
//|   Classic V / Classic A (engulfing base at CLOSE of first candle) |
//|   OCL (open-close gap band) used when Classic engulf fails        |
//|   SBR / RBS (body-close flips)                                    |
//|   QM (Quasimodo: Classic A -> RBS -> RBS broken, right shoulder)  |
//|   Turtle soup strength                                            |
//|                                                                  |
//|  GBO (gap breakout) is named in the source but NOT explained.     |
//|  It is deliberately NOT implemented (stub class + TODO below).   |
//+------------------------------------------------------------------+
#ifndef MSNR_LEVELS_MQH
#define MSNR_LEVELS_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"

enum ENUM_MSNR_LEVEL
{
   MSNR_CLASSIC_V = 0,
   MSNR_CLASSIC_A = 1,
   MSNR_OCL       = 2,
   MSNR_SBR       = 3,
   MSNR_RBS       = 4,
   MSNR_QM        = 5,
   MSNR_GBO       = 6
};

struct MSNR_Level
{
   double            price;       // primary level (close price)
   double            price2;      // OCL band second edge (else == price)
   ENUM_MSNR_LEVEL   type;
   ENUM_TIMEFRAMES   tf;
   datetime          time;
   int               touchCount;
   bool              fresh;
   bool              active;
   bool              strong;      // turtle soup present
   double            slWick;      // left-shoulder wick for QM
};

//--- GBO: named in the source but unexplained. Deliberately left as a stub.
// TODO: implement only if an explicit rule is supplied. Do not invent one.
class CMSNR_GBO
{
public:
   void Init(CStructure* s, const double minGap) {}
   void Rebuild() {}
   int Count() const { return 0; }
};

class CMSNRLevels
{
private:
   CStructure*       m_struct;
   ENUM_TIMEFRAMES   m_tf;
   double            m_minGapPoints;
   double            m_point;
   double            m_qmSlBuffer;
   bool              m_requireTs;
   double            m_protectedRetrace;
   bool              m_allowFreshOnHtf;
   MSNR_Level        m_levels[];
   int               m_count;

   void Add(const double price, const double price2,
            const ENUM_MSNR_LEVEL type, const datetime time,
            const double slWick = 0.0)
   {
      MSNR_Level l;
      l.price = price;
      l.price2 = price2;
      l.type = type;
      l.tf = m_tf;
      l.time = time;
      l.touchCount = 0;
      l.fresh = true;
      l.active = true;
      l.strong = false;
      l.slWick = slWick;
      ArrayResize(m_levels, m_count + 1);
      m_levels[m_count] = l;
      m_count++;
   }

   // A6.2 turtle soup: sweep of previous candle's extreme with close back
   // beyond it. Bullish: Low[i]<Low[i-1] && Close[i]>Low[i-1]. Bearish mirror.
   static bool TurtleSoup(const MqlRates &cur, const MqlRates &prev, int &dir)
   {
      if(cur.low < prev.low && cur.close > prev.low)
      {
         dir = SMC_BULL;
         return true;
      }
      if(cur.high > prev.high && cur.close < prev.high)
      {
         dir = SMC_BEAR;
         return true;
      }
      dir = 0;
      return false;
   }

   void DetectClassicAndOcl()
   {
      int n = (m_struct != NULL) ? m_struct.BarsCount() : 0;
      for(int i = 1; i < n; i++)
      {
         MqlRates prev, cur;
         if(!m_struct.GetRate(i - 1, prev) || !m_struct.GetRate(i, cur))
            continue;
         bool prevBull = prev.close > prev.open;
         bool curBear = cur.close < cur.open;
         bool prevBear = prev.close < prev.open;
         bool curBull = cur.close > cur.open;

         bool classicA = prevBull && curBear && (cur.close < prev.open);
         bool classicV = prevBear && curBull && (cur.close > prev.open);

         if(classicV)
            Add(prev.close, prev.close, MSNR_CLASSIC_V, prev.time,
                prev.low);
         else if(classicA)
            Add(prev.close, prev.close, MSNR_CLASSIC_A, prev.time,
                prev.high);
         else
         {
            double gap = MathAbs(cur.open - prev.close);
            if(gap >= m_minGapPoints * m_point)
               Add(prev.close, cur.open, MSNR_OCL, prev.time);
         }
      }
   }

   // A6.1 flips and A6.2 strength + freshness.
   void ApplyFlipsStrength()
   {
      int n = (m_struct != NULL) ? m_struct.BarsCount() : 0;
      for(int l = 0; l < m_count; l++)
      {
         int origin = -1;
         for(int i = 0; i < n; i++)
         {
            MqlRates r;
            if(m_struct.GetRate(i, r) && r.time == m_levels[l].time)
            {
               origin = i;
               break;
            }
         }
         for(int i = origin + 1; i < n; i++)
         {
            MqlRates r;
            if(!m_struct.GetRate(i, r))
               continue;
            int tsDir = 0;
            if(i > 0)
            {
               MqlRates prev;
               if(m_struct.GetRate(i - 1, prev) && TurtleSoup(r, prev, tsDir))
               {
                  bool sameSide = (m_levels[l].type == MSNR_CLASSIC_V &&
                                   tsDir == SMC_BULL) ||
                                  (m_levels[l].type == MSNR_CLASSIC_A &&
                                   tsDir == SMC_BEAR);
                  if(sameSide)
                     m_levels[l].strong = true;
               }
            }
            bool through = (m_levels[l].type == MSNR_CLASSIC_V ||
                            m_levels[l].type == MSNR_SBR)
                         ? (r.close < m_levels[l].price)
                         : (r.close > m_levels[l].price);
            if(through)
            {
               if(m_levels[l].type == MSNR_CLASSIC_V)
                  m_levels[l].type = MSNR_SBR;
               else if(m_levels[l].type == MSNR_CLASSIC_A)
                  m_levels[l].type = MSNR_RBS;
               m_levels[l].touchCount = 0;
               m_levels[l].fresh = true;
            }
            if(r.low <= m_levels[l].price && r.high >= m_levels[l].price)
            {
               m_levels[l].touchCount++;
               m_levels[l].fresh = false;
            }
         }
      }
   }

   // A6.1 QM: a Classic A that flipped to RBS and whose RBS was then also
   // body-closed through produces a right-shoulder level. SL beyond the left
   // shoulder wick (stored in slWick when the Classic A was created).
   void DetectQuasimodo()
   {
      int n = (m_struct != NULL) ? m_struct.BarsCount() : 0;
      for(int l = 0; l < m_count; l++)
      {
         if(m_levels[l].type != MSNR_RBS)
            continue;
         int origin = -1;
         for(int i = 0; i < n; i++)
         {
            MqlRates r;
            if(m_struct.GetRate(i, r) && r.time == m_levels[l].time)
            {
               origin = i;
               break;
            }
         }
         bool secondBreak = false;
         for(int i = origin + 1; i < n; i++)
         {
            MqlRates r;
            if(!m_struct.GetRate(i, r))
               continue;
            if(r.close < m_levels[l].price)
            {
               secondBreak = true;
               break;
            }
         }
         if(secondBreak)
         {
            Add(m_levels[l].price, m_levels[l].price, MSNR_QM,
                m_levels[l].time, m_levels[l].slWick);
            m_levels[m_count - 1].strong = m_levels[l].strong;
         }
      }
   }

public:
   void Init(CStructure* s, const ENUM_TIMEFRAMES tf, const double minGapPoints,
             const double qmSlBufferPoints, const bool requireTs,
             const double protectedRetracePct, const bool allowFreshOnHtf)
   {
      m_struct = s;
      m_tf = tf;
      m_minGapPoints = minGapPoints;
      m_point = (s != NULL) ? _Point : 0.00001;
      m_qmSlBuffer = qmSlBufferPoints;
      m_requireTs = requireTs;
      m_protectedRetrace = protectedRetracePct;
      m_allowFreshOnHtf = allowFreshOnHtf;
      Reset();
   }

   void Reset()
   {
      ArrayResize(m_levels, 0);
      m_count = 0;
   }

   void Rebuild()
   {
      Reset();
      DetectClassicAndOcl();
      ApplyFlipsStrength();
      DetectQuasimodo();
   }

   int Count() const { return m_count; }
   ENUM_TIMEFRAMES Timeframe() const { return m_tf; }

   bool Get(const int i, MSNR_Level &out)
   {
      if(i < 0 || i >= m_count)
         return false;
      out = m_levels[i];
      return true;
   }

   // A6.2: a level is usable if fresh (or fresh on a higher TF) and,
   // when required, protected by a turtle soup.
   bool Usable(const MSNR_Level &l, CMSNRLevels* higher) const
   {
      bool freshOk = l.fresh;
      if(!freshOk && m_allowFreshOnHtf && higher != NULL)
      {
         for(int i = 0; i < higher.Count(); i++)
         {
            MSNR_Level h;
            if(!higher.Get(i, h) || !h.fresh || !h.active)
               continue;
            if(MathAbs(h.price - l.price) <= m_point)
            {
               freshOk = true;
               break;
            }
         }
      }
      if(!freshOk || !l.active)
         return false;
      if(m_requireTs && !l.strong)
         return false;
      return true;
   }

   bool FreshKeyLevel(const int dir, CMSNRLevels* higher, MSNR_Level &out)
   {
      for(int i = 0; i < m_count; i++)
      {
         MSNR_Level l = m_levels[i];
         if(!Usable(l, higher))
            continue;
         bool sellType = (l.type == MSNR_CLASSIC_A || l.type == MSNR_QM ||
                          l.type == MSNR_RBS);
         if(dir == SMC_BEAR && !sellType)
            continue;
         if(dir == SMC_BULL && sellType)
            continue;
         out = l;
         return true;
      }
      return false;
   }
};

#endif // MSNR_LEVELS_MQH
