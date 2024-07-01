from flask import Flask, render_template, Response, request
from picamera2 import Picamera2, Preview
import io
import time
import psutil
import pynmea2
import serial

app = Flask(__name__)
camera = Picamera2()
camera.configure(camera.create_preview_configuration())
camera.start()

serial_port = '/dev/ttyACM0'
baud_rate = 38400
gps_data = {}

def get_system_info():
    cpu_temp = psutil.sensors_temperatures()['cpu_thermal'][0].current
    mem = psutil.virtual_memory()
    mem_available = mem.available / (1024 * 1024)  # Convert to MB
    throttled = psutil.sensors_temperatures()['cpu_thermal'][0].current > 80
    return {
        'cpu_temp': cpu_temp,
        'mem_available': mem_available,
        'throttled': throttled
    }

def read_gps():
    global gps_data
    ser = serial.Serial(serial_port, baud_rate, timeout=1)
    while True:
        line = ser.readline().decode('ascii', errors='replace')
        if line.startswith('$'):
            msg = pynmea2.parse(line)
            if isinstance(msg, pynmea2.GGA):
                gps_data = {
                    'latitude': msg.latitude,
                    'longitude': msg.longitude,
                    'altitude': msg.altitude,
                    'timestamp': msg.timestamp
                }

@app.route('/')
def index():
    return render_template('index.html')

def gen():
    while True:
        frame = camera.capture_array()
        ret, jpeg = cv2.imencode('.jpg', frame)
        frame = jpeg.tobytes()
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')

@app.route('/video_feed')
def video_feed():
    return Response(gen(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/system_info')
def system_info():
    return get_system_info()

@app.route('/gps_info')
def gps_info():
    return gps_data

@app.route('/set_quality', methods=['POST'])
def set_quality():
    quality = request.form['quality']
    if quality == 'low':
        camera.configure(camera.create_preview_configuration(main={"size": (640, 480)}))
    elif quality == 'medium':
        camera.configure(camera.create_preview_configuration(main={"size": (1280, 720)}))
    elif quality == 'high':
        camera.configure(camera.create_preview_configuration(main={"size": (1920, 1080)}))
    camera.start()
    return '', 204

if __name__ == '__main__':
    from threading import Thread
    gps_thread = Thread(target=read_gps)
    gps_thread.daemon = True
    gps_thread.start()
    app.run(host='0.0.0.0', port=5000, debug=True)
