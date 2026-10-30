self.addEventListener("install",event=>event.waitUntil(self.skipWaiting()));
self.addEventListener("activate",event=>event.waitUntil(self.clients.claim()));
self.addEventListener("push",event=>{
  let payload={title:"Ordem de serviço",body:"Há um serviço próximo do horário.",id:""};
  try{payload={...payload,...event.data.json()}}catch{}
  event.waitUntil(self.registration.showNotification(payload.title,{
    body:payload.body,icon:"./icon.svg",badge:"./icon.svg",tag:`os-${payload.id}`,
    data:{id:payload.id,url:payload.url||"./"},actions:[{action:"execute",title:"Executar"},{action:"snooze",title:"Lembre-me mais tarde"}]
  }));
});
self.addEventListener("notificationclick",event=>{
  event.notification.close();
  const action=event.action==="execute"?"execute":event.action==="snooze"?"snooze":"";
  const data=event.notification.data||{};
  const target=new URL(data.url||"./",self.location.href);
  if(action){target.searchParams.set("action",action);target.searchParams.set("id",data.id||"")}
  event.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(clients=>{
    for(const client of clients){if("focus" in client)return client.navigate(target.href).then(c=>c&&c.focus())}
    return self.clients.openWindow(target.href)
  }));
});
