document.querySelectorAll('[data-action]').forEach(button => {
  button.addEventListener('click', () => window.webkit?.messageHandlers?.player?.postMessage(button.dataset.action));
});
