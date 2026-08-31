/* cube_db 讲义共享脚本 — sidenav toggle 逻辑 */
(function(){
  var toggle = document.getElementById('navToggle');
  var sidenav = document.getElementById('sidenav');
  if (!toggle || !sidenav) return;
  toggle.addEventListener('click', function(e){
    e.stopPropagation();
    sidenav.classList.toggle('open');
    document.body.classList.toggle('sidenav-open', sidenav.classList.contains('open'));
    toggle.setAttribute('aria-expanded', sidenav.classList.contains('open'));
  });
  sidenav.querySelectorAll('a').forEach(function(a){
    a.addEventListener('click', function(){
      sidenav.classList.remove('open');
      document.body.classList.remove('sidenav-open');
      toggle.setAttribute('aria-expanded', 'false');
    });
  });
  document.addEventListener('click', function(e){
    if (document.body.classList.contains('sidenav-open') && !sidenav.contains(e.target) && e.target !== toggle) {
      sidenav.classList.remove('open');
      document.body.classList.remove('sidenav-open');
      toggle.setAttribute('aria-expanded', 'false');
    }
  });
})();
