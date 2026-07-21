function showUnit(i){
  document.querySelectorAll('.unit-tab').forEach((t,j)=>t.classList.toggle('active',i===j));
  document.querySelectorAll('.unit-content').forEach((c,j)=>c.classList.toggle('active',i===j));
  window.scrollTo({top:0,behavior:'smooth'});
}
function checkQ(btn,correct){
  const group=btn.closest('.quiz-options');
  if(group.querySelector('.correct,.wrong'))return;
  btn.classList.add(correct?'correct':'wrong');
  if(!correct)group.querySelectorAll('button').forEach(b=>{if(b.onclick.toString().includes('true'))b.classList.add('correct')});
  group.querySelectorAll('button').forEach(b=>b.disabled=true);
}
function toggleAns(btn){
  const rev=btn.nextElementSibling;
  const s=rev.classList.contains('show');
  rev.classList.toggle('show');
  btn.textContent=s?'정답 보기 🔍':'정답 숨기기 🙈';
  btn.style.background=s?'linear-gradient(90deg,var(--primary),var(--accent))':'linear-gradient(90deg,#EF4444,#DC2626)';
}
// Grammar tab styles
document.querySelectorAll('.gram-btn').forEach((b,i)=>{
  b.style.cssText='background:#F8F0F3;border:1.5px solid var(--border);border-radius:24px;padding:8px 16px;cursor:pointer;font-size:13px;font-weight:600;color:var(--muted);transition:all .2s';
  b.onmouseenter=()=>{if(!b.classList.contains('active'))b.style.borderColor='var(--primary)'};
  b.onmouseleave=()=>{if(!b.classList.contains('active'))b.style.borderColor='var(--border)'};
});
function switchGram(i){
  document.querySelectorAll('.gram-btn').forEach((b,j)=>{
    b.classList.toggle('active',i===j);
    b.style.background=i===j?'linear-gradient(90deg,var(--primary),var(--accent))':'#F8F0F3';
    b.style.color=i===j?'#fff':'var(--muted)';
    b.style.borderColor=i===j?'transparent':'var(--border)';
  });
  for(let n=0;n<5;n++){
    const el=document.getElementById('gp'+n);
    if(el)el.style.display=n===i?'block':'none';
  }
}
// Init grammar panels
for(let n=1;n<5;n++){const el=document.getElementById('gp'+n);if(el)el.style.display='none';}
