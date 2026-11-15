/* Reversible visual concept. No access to recordings, credentials or device APIs. */
(()=>{
 const css=document.createElement('link');css.rel='stylesheet';css.href='scroll-concept.css';document.head.appendChild(css);
 const bold=document.createElement('link');bold.rel='stylesheet';bold.href='scroll-bold.css';document.head.appendChild(bold);
 const experience=document.createElement('link');experience.rel='stylesheet';experience.href='experience.css';document.head.appendChild(experience);
 document.body.classList.add('scroll-concept');
 const root=document.querySelector('#content'),reduced=matchMedia('(prefers-reduced-motion: reduce)');
 const motionToggle=document.createElement('button');motionToggle.className='concept-motion';motionToggle.textContent=reduced.matches?'▶ Play animations':'Ⅱ Pause animations';motionToggle.setAttribute('aria-pressed',String(!reduced.matches));document.body.appendChild(motionToggle);
 let motionOn=!reduced.matches;
 motionToggle.onclick=()=>{motionOn=!motionOn;document.body.classList.toggle('motion-demo',motionOn);document.documentElement.classList.toggle('motion-demo',motionOn);document.body.classList.toggle('motion-paused',!motionOn);motionToggle.textContent=motionOn?'Ⅱ Pause animations':'▶ Play animations';motionToggle.setAttribute('aria-pressed',String(motionOn));update()};
 if(!motionOn)document.body.classList.add('motion-paused');
 const progress=document.createElement('div');progress.className='scroll-progress';progress.setAttribute('aria-hidden','true');document.body.appendChild(progress);
 let pending=false;
 let lastPage='',forwarding=false;
 // Wrap the existing navigation click, preserving its auth and recording guards.
 document.addEventListener('click',event=>{
  const button=event.target.closest('button[data-view]');
  if(!button||forwarding||!motionOn||!document.startViewTransition)return;
  event.preventDefault();event.stopImmediatePropagation();
  const order=['home','studio','library'],next=button.dataset.view;
  root.style.setProperty('--page-direction',order.indexOf(next)<order.indexOf(lastPage)?'-1':'1');
  document.startViewTransition(()=>{forwarding=true;try{button.click();enhance()}finally{forwarding=false}});
 },true);
 const reveal=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){entry.target.classList.add('is-visible');reveal.unobserve(entry.target)}},{threshold:.12});
 function enhance(){
  const hero=root.querySelector('.hero');
  document.body.classList.toggle('concept-home',Boolean(hero));
  const page=hero?'home':root.querySelector('.studio-grid')?'studio':root.querySelector('.report-grid')?'report':'library';
  document.body.dataset.chapter=page;
  const heading=root.querySelector(':scope > .heading');
  if(heading&&!heading.dataset.chapterReady&&(page==='studio'||page==='library')){
   heading.dataset.chapterReady='true';heading.classList.add('chapter-head');
   const title=heading.querySelector('h1');if(title)title.innerHTML=page==='studio'?'Make room<br><em>for your voice.</em>':'Every rehearsal.<br><em>A little further.</em>';
   const number=document.createElement('span');number.className='chapter-number';number.setAttribute('aria-hidden','true');number.textContent=page==='studio'?'02':'03';heading.appendChild(number);
  }
  if(page!==lastPage){
   lastPage=page;root.classList.remove('chapter-arrive');
   if(motionOn){void root.offsetWidth;root.classList.add('chapter-arrive')}
   window.scrollTo({top:0,behavior:'instant'});
  }
  if(hero&&!hero.dataset.scrollConcept){
   hero.dataset.scrollConcept='true';
   hero.querySelector('h2').innerHTML='Own the<br><em>moment.</em>';
   hero.querySelector('.pill').textContent='A SPACE TO BECOME';
   const art=hero.querySelector('.stage-art');
   art.innerHTML='<div class="sculpture-halo"></div><div class="sculpture"><div class="sculpture-core"></div><div class="sculpture-ring ring-one"></div><div class="sculpture-ring ring-two"></div><div class="sculpture-ring ring-three"></div></div><span class="art-caption">A LITTLE PRACTICE.<br>AN ENTIRELY NEW PERSPECTIVE.</span><span class="art-coordinate">SS / 001</span>';
   const scrollHint=document.createElement('div');scrollHint.className='scroll-hint';scrollHint.setAttribute('aria-hidden','true');scrollHint.innerHTML='<span>SCROLL TO FIND YOUR FLOW</span><i>↓</i>';hero.appendChild(scrollHint);
   const benefits=document.createElement('div');benefits.className='hero-benefits';benefits.setAttribute('aria-label','Practice benefits');benefits.innerHTML='<span class="benefit-float benefit-ai"><i aria-hidden="true">✦</i> AI-powered reflection</span><span class="benefit-float benefit-message"><i aria-hidden="true">↗</i> Sharper ideas</span><span class="benefit-float benefit-practice"><i aria-hidden="true">◉</i> Practice with purpose</span>';hero.appendChild(benefits);
   const story=document.createElement('section');story.className='flow-story';story.setAttribute('aria-label','Your practice journey');
   story.innerHTML='<div class="flow-intro"><span class="flow-kicker">THE SPACE BETWEEN<br>AN IDEA AND ITS IMPACT.</span><h2>Good ideas deserve<br>a <em>great delivery.</em></h2><p>Give yourself room to rehearse.<br>Make the next time feel like your time.</p></div><div class="flow-cards"><article class="flow-card"><span class="flow-number">01 / PRACTICE</span><div class="flow-symbol symbol-record" aria-hidden="true"><i></i></div><h3>Make space<br>for your voice.</h3><p>Set your stage. Enable your devices, confirm consent, and rehearse at your own pace.</p></article><article class="flow-card"><span class="flow-number">02 / REFLECT</span><div class="flow-symbol symbol-wave" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div><h3>See the moment.<br>Hear the difference.</h3><p>Return to your recording. Notice your opening, your rhythm, and the way your ideas connect.</p></article><article class="flow-card"><span class="flow-number">03 / REPEAT</span><div class="flow-symbol symbol-orbit" aria-hidden="true"><i></i></div><h3>A little better.<br>Every single time.</h3><p>Choose one thing to work on. Take it into your next rehearsal and keep your progress moving.</p></article></div>';
   hero.after(story);
   const band=document.createElement('div');band.className='concept-band';band.setAttribute('aria-hidden','true');band.innerHTML='<div>YOUR VOICE. YOUR STAGE. &nbsp;✦&nbsp; PRACTICE WITH PURPOSE. &nbsp;✦&nbsp; YOUR VOICE. YOUR STAGE. &nbsp;✦&nbsp; PRACTICE WITH PURPOSE. &nbsp;✦&nbsp;</div>';story.before(band);
  }
  root.querySelectorAll('.flow-intro,.flow-card,.stats>.stat,.recording-empty,.sample-examples,.bottom-grid>.note,.grid>.session').forEach(el=>{if(el.dataset.scrollReveal)return;el.dataset.scrollReveal='true';if(!reduced.matches){el.classList.add('scroll-reveal');reveal.observe(el)}});
  update();
 }
 function update(){pending=false;
  const max=document.documentElement.scrollHeight-innerHeight;
  progress.style.transform=`scaleX(${max>0?scrollY/max:0})`;
  const hero=root.querySelector('.hero');if(!hero||!motionOn)return;
  const rect=hero.getBoundingClientRect(),value=Math.max(0,Math.min(1,-rect.top/rect.height));
  hero.style.setProperty('--scroll',value.toFixed(3));
 }
 function schedule(){if(!pending){pending=true;requestAnimationFrame(update)}}
 let enhancementQueued=false;
 new MutationObserver(()=>{if(!enhancementQueued){enhancementQueued=true;requestAnimationFrame(()=>{enhancementQueued=false;enhance()})}}).observe(root,{childList:true,subtree:true});
 addEventListener('scroll',schedule,{passive:true});addEventListener('resize',schedule);reduced.addEventListener('change',()=>{if(reduced.matches){reveal.disconnect();root.querySelectorAll('.scroll-reveal').forEach(el=>el.classList.add('is-visible'))}update()});enhance();
})();
