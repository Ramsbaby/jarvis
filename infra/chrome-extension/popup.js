document.addEventListener('DOMContentLoaded', () => {
  const statusEl = document.getElementById('status');
  const resultEl = document.getElementById('result');
  const runBtn = document.getElementById('runBtn');

  // 상태 조회
  chrome.runtime.sendMessage({ type: 'GET_STATUS' }, (res) => {
    if (res) {
      statusEl.innerHTML = `
        마지막 실행: ${res.lastRun}<br>
        누적 seen: ${res.seenCount}건<br>
        주기: 4시간마다 자동 실행
      `;
    }
  });

  // 수동 실행
  runBtn.addEventListener('click', () => {
    runBtn.disabled = true;
    runBtn.textContent = '크롤링 중...';
    resultEl.textContent = '';

    chrome.runtime.sendMessage({ type: 'RUN_NOW' }, (res) => {
      runBtn.disabled = false;
      runBtn.textContent = '지금 바로 크롤링';
      resultEl.textContent = res?.ok ? '✅ 완료! Discord 확인하세요.' : '❌ 실패. 콘솔 확인.';
    });
  });
});
