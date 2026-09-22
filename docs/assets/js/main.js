// Mobile nav + copy + tabs
document.addEventListener('DOMContentLoaded', ()=>{
  const btn = document.querySelector('[data-hamburger]');
  const links = document.querySelector('.nav-links');
  if(btn && links){ btn.addEventListener('click', ()=> links.classList.toggle('open')); }

  document.querySelectorAll('[data-copy]').forEach(b=>{
    b.addEventListener('click', async ()=>{
      const sel = b.getAttribute('data-copy');
      const el = document.querySelector(sel);
      if(!el) return;
      await navigator.clipboard.writeText(el.innerText);
      b.textContent='Copied!'; setTimeout(()=> b.textContent='Copy', 1200);
    });
  });

  document.querySelectorAll('.tabs').forEach(group=>{
    const tabs = group.querySelectorAll('.tab');
    const panes = document.querySelectorAll(group.getAttribute('data-panes'));
    tabs.forEach((t)=>{
      t.addEventListener('click', ()=>{
        tabs.forEach(x=>x.classList.remove('active'));
        t.classList.add('active');
        panes.forEach(p=>p.style.display='none');
        const target = document.querySelector(t.getAttribute('data-target'));
        if(target) target.style.display='block';
      });
    });
  });

  // Step grid — click to expand
  document.querySelectorAll('.step[data-step]').forEach(s=>{
    const detail = s.querySelector('.step-detail');
    const toggle = ()=>{
      const open = s.getAttribute('aria-expanded')==='true';
      s.setAttribute('aria-expanded', String(!open));
      if(detail) detail.style.display = open ? 'none' : 'block';
      s.style.borderColor = open ? 'var(--line)' : 'var(--profit)';
      s.style.boxShadow = open ? '0 4px 12px rgba(10,15,31,.04)' : '0 8px 18px var(--profit-ring)';
    };
    s.addEventListener('click', toggle);
    s.addEventListener('keydown', e=>{ if(e.key==='Enter' || e.key===' '){ e.preventDefault(); toggle(); }});
  });

  // Hero ledger — drag expiry price, collateral never moves
  const heroPrice = document.getElementById('hero-price');
  if(heroPrice){
    const priceV = document.getElementById('hero-price-v');
    const buyerV = document.getElementById('hero-buyer');
    const writerV = document.getElementById('hero-writer');
    const pill = document.getElementById('hero-pill');
    const sum = document.getElementById('hero-sum');
    const K = 10;
    const update = ()=>{
      const S = parseFloat(heroPrice.value);
      const buyer = S > K ? (S - K)/S : 0;
      const writer = 1 - buyer;
      if(priceV) priceV.innerHTML = `$${S.toFixed(2)} <span style="color:var(--indigo)">at expiry</span>`;
      if(buyerV) buyerV.textContent = `${buyer.toFixed(2)} WMON / ticket`;
      if(writerV) writerV.textContent = `${writer.toFixed(2)} WMON / ticket`;
      if(pill) pill.textContent = `$${S.toFixed(2)}`;
      if(sum) sum.textContent = `buyer + writer = ${(buyer+writer).toFixed(2)} ✓`;
      // subtle pulse when in the money
      if(buyer > 0){ pill.style.background='var(--profit)'; pill.style.color='white'; } else { pill.style.background='var(--profit-soft)'; pill.style.color='var(--profit-ink)'; }
    };
    heroPrice.addEventListener('input', update); update();
  }

  // Profit calculator + payoff hockey-stick
  const calc = document.getElementById('calc');
  const payoffPath = document.getElementById('payoff-path');
  const payoffStrike = document.getElementById('payoff-strike');
  const payoffDot = document.getElementById('payoff-dot');
  const payoffAnnotation = document.getElementById('payoff-annotation');
  const payoffLabel = document.getElementById('payoff-label');

  function drawPayoff(isCall, K, S, premium){
    if(!payoffPath) return;
    const svg = payoffPath.ownerSVGElement;
    const W=640, H=240, padL=52, padR=18, padT=18, padB=38;
    const innerW = W - padL - padR, innerH = H - padT - padB;
    const lo = Math.min(K*0.45, S*0.85, K-6), hi = Math.max(K*1.65, S*1.15, K+8);
    const span = hi - lo;
    const x = p => padL + (p - lo)/span * innerW;
    const maxPayout = isCall ? (hi-K)/hi : (K - lo);
    const yScale = maxPayout > 0 ? innerH / (maxPayout*1.18) : innerH;
    const y = payout => (padT + innerH) - payout * yScale;

    // clear previous grid
    const existing = svg.querySelectorAll('.grid');
    existing.forEach(n=>n.remove());

    // subtle horizontal grid + labels
    const gridLevels = [0, maxPayout*0.5, maxPayout];
    gridLevels.forEach(val=>{
      const gy = y(val);
      const line = document.createElementNS('http://www.w3.org/2000/svg','line');
      line.setAttribute('x1', padL); line.setAttribute('x2', W-padR);
      line.setAttribute('y1', gy); line.setAttribute('y2', gy);
      line.setAttribute('stroke', '#EFE9DD'); line.setAttribute('stroke-width','1'); line.setAttribute('stroke-dasharray','3 5'); line.setAttribute('class','grid');
      svg.insertBefore(line, payoffPath);
      const txt = document.createElementNS('http://www.w3.org/2000/svg','text');
      txt.setAttribute('x', padL-8); txt.setAttribute('y', gy+3);
      txt.setAttribute('text-anchor','end'); txt.setAttribute('font-family','JetBrains Mono'); txt.setAttribute('font-size','10'); txt.setAttribute('fill','#8A95A5'); txt.setAttribute('class','grid');
      txt.textContent = val.toFixed(2);
      svg.insertBefore(txt, payoffPath);
    });
    // vertical ticks at lo, K, hi
    [lo, K, hi].forEach(val=>{
      const tx = x(val);
      const tline = document.createElementNS('http://www.w3.org/2000/svg','line');
      tline.setAttribute('x1', tx); tline.setAttribute('x2', tx);
      tline.setAttribute('y1', padT+innerH); tline.setAttribute('y2', padT+innerH+4);
      tline.setAttribute('stroke','#E2D5B8'); tline.setAttribute('stroke-width','1.2'); tline.setAttribute('class','grid');
      svg.insertBefore(tline, payoffPath);
      const ttxt = document.createElementNS('http://www.w3.org/2000/svg','text');
      ttxt.setAttribute('x', tx); ttxt.setAttribute('y', padT+innerH+16);
      ttxt.setAttribute('text-anchor','middle'); ttxt.setAttribute('font-family','JetBrains Mono'); ttxt.setAttribute('font-size','10'); ttxt.setAttribute('fill','#6B7280'); ttxt.setAttribute('font-weight','600'); ttxt.setAttribute('class','grid');
      ttxt.textContent = `$${val.toFixed(0)}` + (val===K?'  strike':'');
      svg.insertBefore(ttxt, payoffPath);
    });

    // area fill under curve
    let area = svg.querySelector('#payoff-area');
    if(!area){ area = document.createElementNS('http://www.w3.org/2000/svg','path'); area.id='payoff-area'; svg.insertBefore(area, payoffPath); }
    let d='', ad='';
    const steps=140;
    for(let i=0;i<=steps;i++){
      const p = lo + i/steps * span;
      const pay = isCall ? (p>K ? (p-K)/p : 0) : (p<K ? (K-p) : 0);
      const px=x(p), py=y(pay);
      d += i===0 ? `M ${px} ${py}` : ` L ${px} ${py}`;
      ad += i===0 ? `M ${px} ${y(0)} L ${px} ${py}` : ` L ${px} ${py}`;
    }
    ad += ` L ${x(hi)} ${y(0)} Z`;
    area.setAttribute('d', ad);
    area.setAttribute('fill', isCall ? 'rgba(14,164,122,.08)' : 'rgba(244,63,94,.07)');
    area.setAttribute('stroke','none');

    payoffPath.setAttribute('d', d);
    payoffPath.setAttribute('stroke', isCall ? '#0EA67A' : '#F43F5E');
    payoffPath.setAttribute('stroke-width','2.8');
    payoffPath.setAttribute('stroke-linecap','round'); payoffPath.setAttribute('stroke-linejoin','round');
    const sx = x(K);
    payoffStrike.setAttribute('x1', sx); payoffStrike.setAttribute('x2', sx);
    payoffStrike.setAttribute('y1', padT); payoffStrike.setAttribute('y2', padT+innerH);
    payoffStrike.setAttribute('stroke','#FF9500'); payoffStrike.setAttribute('stroke-dasharray','7 5'); payoffStrike.setAttribute('stroke-width','1.6');
    const curPay = isCall ? (S>K ? (S-K)/S : 0) : (S<K ? (K-S) : 0);
    const cx=x(S), cy=y(curPay);
    payoffDot.setAttribute('cx', cx); payoffDot.setAttribute('cy', cy); payoffDot.setAttribute('r', '7');
    payoffDot.setAttribute('fill', curPay>premium ? (isCall?'#0EA67A':'#E11D48') : (curPay>0 ? '#10B981' : '#9CA3AF'));
    payoffDot.setAttribute('stroke','white'); payoffDot.setAttribute('stroke-width','2.2');
    if(payoffAnnotation){
      payoffAnnotation.setAttribute('x', Math.min(Math.max(cx+12, padL+8), W-110));
      payoffAnnotation.setAttribute('y', Math.max(cy-14, padT+14));
      payoffAnnotation.setAttribute('font-family','Inter'); payoffAnnotation.setAttribute('font-size','12'); payoffAnnotation.setAttribute('font-weight','700'); payoffAnnotation.setAttribute('fill','#0A0F1F');
      payoffAnnotation.setAttribute('paint-order','stroke'); payoffAnnotation.setAttribute('stroke','white'); payoffAnnotation.setAttribute('stroke-width','4'); payoffAnnotation.setAttribute('stroke-linejoin','round');
      const profit = curPay - premium;
      payoffAnnotation.textContent = `S $${S.toFixed(2)} → ${curPay.toFixed(2)} ${profit>=0?`(+${profit.toFixed(2)})`:`(${profit.toFixed(2)})`}`;
    }
  }

  if(calc && payoffPath){
    const amt = document.getElementById('calc-amt');
    const prem = document.getElementById('calc-prem');
    const strike = document.getElementById('calc-strike');
    const price = document.getElementById('calc-price');
    const type = document.getElementById('calc-type');
    const outPayout = document.getElementById('calc-payout');
    const outProfit = document.getElementById('calc-profit');
    const outBreak = document.getElementById('calc-break');
    function fmt(n){ return n.toLocaleString(undefined,{maximumFractionDigits:4}); }
    function compute(){
      const a = parseFloat(amt.value||'0');
      const pr = parseFloat(prem.value||'0');
      const K = parseFloat(strike.value||'0');
      const S = parseFloat(price.value||'0');
      const isCall = type.value==='call';
      let per = 0;
      if(isCall){ per = S>K ? (S-K)/S : 0; } else { per = S<K ? (K-S) : 0; }
      const gross = a * per;
      const fee = gross>0 ? gross*0.0025 : 0;
      const net = gross - fee;
      const cost = a * pr;
      const profit = net - cost;
      if(outPayout) outPayout.textContent = fmt(net);
      if(outProfit){ outProfit.textContent = (profit>=0?'+':'')+fmt(profit); outProfit.style.color = profit>=0 ? '#0E7A5F' : '#B42318'; }
      let be='—';
      if(isCall && pr>0) be = `≈ $${fmt(K/(1-pr))} (needs payout = premium)`;
      if(!isCall && pr>0) be = `≈ $${fmt(K - pr)}`;
      if(outBreak) outBreak.textContent = be;
      if(payoffLabel) payoffLabel.textContent = `${isCall?'Call':'Put'} • Strike $${K}`;
      payoffLabel.className = 'pill ' + (isCall ? 'mint' : 'rose');
      drawPayoff(isCall, K, S, pr);
      // sync hero if on same page? no
    }
    [amt,prem,strike,price,type].forEach(el=> el && el.addEventListener('input', compute));
    compute();
  } else if(payoffPath){
    // index hero fallback: draw default call K=10 S=12.5
    drawPayoff(true, 10, 12.5, 0.4);
    const hero = document.getElementById('hero-price');
    if(hero){ hero.addEventListener('input', ()=> drawPayoff(true, 10, parseFloat(hero.value), 0.4)); }
  }
});
