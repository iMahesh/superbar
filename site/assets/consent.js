/* Cookie consent. The head script sets Google's consent to denied and loads Microsoft
   Clarity only when the stored choice is "granted". This shows the banner until the
   visitor chooses, and lets them change the choice from "Cookie settings". */
(() => {
  'use strict';
  const KEY = 'superbar-consent';
  const banner = document.getElementById('consent');
  if (!banner) return;

  const save = value => { try { localStorage.setItem(KEY, value); } catch (e) { /* private mode: ask again next visit */ } };
  const all = state => ({ ad_storage: state, ad_user_data: state, ad_personalization: state, analytics_storage: state });
  const show = () => { banner.hidden = false; document.getElementById('consent-accept').focus({ preventScroll: true }); };
  const hide = () => { banner.hidden = true; };

  document.getElementById('consent-accept').addEventListener('click', () => {
    save('granted');
    window.superbarConsent = 'granted';
    window.gtag && window.gtag('consent', 'update', all('granted'));
    window.loadClarity && window.loadClarity();
    hide();
  });

  document.getElementById('consent-decline').addEventListener('click', () => {
    save('denied');
    window.superbarConsent = 'denied';
    window.gtag && window.gtag('consent', 'update', all('denied'));
    if (window.clarityLoaded && window.clarity) {
      // Tell Clarity consent was withdrawn: it stops tracking and erases its cookies.
      window.clarity('consentv2', { ad_Storage: 'denied', analytics_Storage: 'denied' });
      window.clarity('consent', false);
    }
    hide();
  });

  banner.addEventListener('keydown', e => { if (e.key === 'Escape') hide(); });
  const settings = document.getElementById('consent-settings');
  if (settings) settings.addEventListener('click', show);

  if (window.superbarConsent !== 'granted' && window.superbarConsent !== 'denied') show();
})();
