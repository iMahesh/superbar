/* Superbar site. Every picture is a real screenshot from Superbar's snapshot mode
   (tools/snap.sh); this script only wires the GitHub link and the copy buttons. */
(() => {
  'use strict';

  // Set this to the repository's URL to show a "View on GitHub" button in the hero.
  const REPO_URL = '';

  if (REPO_URL) {
    const a = document.querySelector('#repo-link');
    a.href = REPO_URL;
    a.hidden = false;
  }

  document.querySelectorAll('.copy').forEach(b => b.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = 'Copied'; }
    catch { b.textContent = 'Select and copy'; }
    setTimeout(() => { b.textContent = 'Copy'; }, 1600);
  }));
})();
