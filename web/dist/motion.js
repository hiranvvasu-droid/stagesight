// Progressive visual enhancement only; recording, storage and auth stay independent.
// Animated design is the default; the prior layout remains available for rollback.
if(new URLSearchParams(location.search).get('design')!=='original'){
 const concept=document.createElement('script');concept.src='scroll-concept.js';document.head.appendChild(concept);
}
(()=>{
 const root=document.querySelector('#content');if(!root)return;
 const reduced=matchMedia('(prefers-reduced-motion: reduce)');let queued=false;
 function enhance(){queued=false;
  const hero=root.querySelector('.hero-copy');if(hero&&!hero.querySelector('.practice-rhythm')){const rhythm=document.createElement('div');rhythm.className='practice-rhythm';rhythm.setAttribute('aria-hidden','true');rhythm.innerHTML='<span>Practice</span><i></i><span>Reflect</span><i></i><span>Repeat</span>';hero.appendChild(rhythm)}
  const studio=root.querySelector('.studio-grid');if(studio&&!root.querySelector('.setup-journey')){const steps=document.createElement('div');steps.className='setup-journey';steps.setAttribute('aria-label','Practice session steps');steps.innerHTML='<div class="journey-step"><b>01</b><div><strong>Set your stage</strong><span>Devices & consent</span></div></div><div class="journey-step"><b>02</b><div><strong>Make it yours</strong><span>Record your rehearsal</span></div></div><div class="journey-step"><b>03</b><div><strong>Find your next step</strong><span>Replay & reflect</span></div></div>';studio.before(steps)}
  const player=root.querySelector('.video-wrap');if(player)player.classList.toggle('is-recording',Boolean(root.querySelector('#stop')&&!root.querySelector('#stop').disabled));
  const candidates=root.querySelectorAll(':scope > .heading,:scope > .hero,:scope > .setup-journey,:scope > .section-head,:scope > .recording-empty,.stats > .stat,.grid > .session,.bottom-grid > .note,.studio-grid > div,.report-grid > div');
  let index=0;for(const item of candidates){if(item.dataset.motionReady)continue;item.dataset.motionReady='true';if(!reduced.matches){item.style.setProperty('--enter-delay',Math.min(index++*40,200)+'ms');item.classList.add('motion-enter')}}
 }
 const observer=new MutationObserver(()=>{if(!queued){queued=true;requestAnimationFrame(enhance)}});observer.observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['disabled']});enhance();
 document.addEventListener('click',event=>{const button=event.target.closest('button.primary,button.secondary');if(!button||button.disabled||reduced.matches)return;const rect=button.getBoundingClientRect(),ink=document.createElement('span');ink.className='click-ink';ink.setAttribute('aria-hidden','true');ink.style.left=(event.detail?event.clientX-rect.left:rect.width/2)+'px';ink.style.top=(event.detail?event.clientY-rect.top:rect.height/2)+'px';button.appendChild(ink);setTimeout(()=>ink.remove(),700)});
})();
