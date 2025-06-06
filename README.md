📸 SmartThings Edge Driver for ONVIF Cameras & Reolink Doorbells
Seamlessly integrate ONVIF-compliant cameras and Reolink POE Doorbells into SmartThings, with enhanced doorbell functionality mimicking Ring devices.

🚀 Features
📹 Stream video from ONVIF Profile S cameras.

🚪 Doorbell press notifications (SmartThings TV & Hub compatible).

🎥 Automatic snapshot refresh.

🎚️ Two-way audio & chime control for Reolink Doorbells.

🏃 Motion detection & routine triggers.

🔧 Supports NVR-based streaming (Reolink RLN36).

⚙️ Requirements
SmartThings Hub (Edge compatible)

SmartThings mobile app

ONVIF Profile S cameras or Reolink Doorbell

Proper network configuration (same subnet, ONVIF enabled)

📥 Installation
Enroll in the Edge channel: [Link Pending]

Install driver to your SmartThings hub.

Use Add Device > Scan Nearby to discover cameras and doorbells.

🎮 Usage
Configure device settings (IP, credentials, NVR options).

Tap Refresh to initialize streams and event subscriptions.

For Doorbells:

Receive push notifications on press.

Use two-way audio and chime controls via SmartThings app.

Add devices to a Camera Group for live streaming view.

🔔 Automations
Trigger routines on:

Doorbell press.

Motion detection.

Example:
"If Doorbell Pressed ➜ Play Chime & Send Notification."

⚠️ Known Limitations
SmartThings streams only viewable via Camera Groups.

Motion events may fail if devices are behind firewalls or on separate subnets.

RTSP URL exposes credentials due to SmartThings platform limits.

📑 Supported Devices
Reolink: POE Doorbells, E1 Pro, RLC Series

Hikvision, Foscam, Axis, TP-Link TAPO, and more.

For detailed compatibility, see Full Device List.