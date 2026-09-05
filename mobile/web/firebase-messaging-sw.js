importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyAvFVbCwYqAoeQe3hF0w5r88CZ1sxVsW80",
  authDomain: "cn-call-3feb3.firebaseapp.com",
  projectId: "cn-call-3feb3",
  storageBucket: "cn-call-3feb3.firebasestorage.app",
  messagingSenderId: "266880203721",
  appId: "1:266880203721:web:361127843c34d468774618"
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  console.log("[CN CALL] BACKGROUND RECEIVED", payload);
  console.log("[CN CALL] FCM background message:", payload);

  const notification = payload.notification || {};
  const data = payload.data || {};

  self.registration.showNotification(
    notification.title || "CN CALL",
    {
      body: notification.body || "مكالمة واردة",
      icon: "/icons/Icon-192.png",
      data: data,
      tag: "cn-call-incoming",
      requireInteraction: true
    }
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  event.waitUntil(
    clients.matchAll({
      type: "window",
      includeUncontrolled: true
    }).then((clientList) => {
      for (const client of clientList) {
        if ("focus" in client) {
          return client.focus();
        }
      }

      if (clients.openWindow) {
        return clients.openWindow("/");
      }
    })
  );
});
