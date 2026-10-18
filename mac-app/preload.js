// The only bridge between the page and the Mac: save files, open the folder, hear menu commands.
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('desktop', {
  mirror: (songs) => ipcRenderer.invoke('songs:mirror', songs),
  openFolder: () => ipcRenderer.invoke('songs:open'),
  onMenu: (fn) => ipcRenderer.on('menu', (e, action) => fn(action)),
  setOpenAIKey: (key) => ipcRenderer.invoke('openai:setKey', key),
  hasOpenAIKey: () => ipcRenderer.invoke('openai:hasKey'),
  testOpenAI: () => ipcRenderer.invoke('openai:test'),
  aiJson: (prompt, modelTier) => ipcRenderer.invoke('openai:json', { prompt: prompt, modelTier: modelTier }),
  openExternal: (url) => ipcRenderer.invoke('shell:openExternal', url),
  micAccess: () => ipcRenderer.invoke('mic:access'),
  openMicSettings: () => ipcRenderer.invoke('mic:settings'),
  onAuthCallback: (fn) => ipcRenderer.on('auth-callback', (e, url) => fn(url)),
  getDevLimit: () => ipcRenderer.invoke('dev:getLimit'),
  setDevLimit: (n) => ipcRenderer.invoke('dev:setLimit', n)
});
