"""Generates Taskfold's completion sound: a soft two-note sine pluck (original, no samples)."""
import math, struct, sys, wave

RATE = 44100
def note(freq, start, length, amp):
    out = []
    for i in range(int(length * RATE)):
        t = i / RATE
        env = (min(1.0, t / 0.004)) * math.exp(-t * 18)          # 4 ms attack, fast decay
        s = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * freq * 2 * t)  # warm 2nd harmonic
        out.append((start + i, amp * env * s / 1.25))
    return out

length = 0.24
buf = [0.0] * int(length * RATE)
for idx, v in note(1318.5, 0, 0.16, 0.30) + note(1760.0, int(0.055 * RATE), 0.185, 0.26):   # E6 then A6
    if idx < len(buf): buf[idx] += v
tail = int(0.02 * RATE)
for i in range(tail): buf[-tail + i] *= 1 - i / tail                 # click-free end
with wave.open(sys.argv[1] if len(sys.argv) > 1 else "complete.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in buf))
