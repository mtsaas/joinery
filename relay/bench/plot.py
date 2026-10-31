# Draws throughput.png and small-host.png from the runs in load-results.md ("Both tests on the finished build").
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
blue, orange = '#2a78d6', '#eb6834'
plt.rcParams.update({'font.size': 12, 'axes.spines.top': False})

# Test 1: 16 cores, 8 loops, rooms of four at 1,000 changes/s each; every run of the search
deliveries = [0.30, 0.60, 1.20, 2.40, 4.80, 5.40, 5.70, 5.93, 7.33, 8.83]   # million a second
memory = [121, 256, 526, 1159, 2621, 3286, 3566, 3882, 4951, 6877]           # MB at peak
cpu = [4, 11, 19, 36, 51, 51, 52, 51, 50, 51]                                # % of the machine's 16 cores
fig, ax = plt.subplots(figsize=(8, 4.5), dpi=200)
ax.plot(deliveries, memory, color=blue, marker='o', lw=2, label='memory')
ax.set_xlabel('million deliveries / s'); ax.set_ylabel('memory (MB)', color=blue); ax.set_ylim(0, 7500)
cx = ax.twinx()
cx.plot(deliveries, cpu, color=orange, marker='s', lw=2, label='CPU')
cx.set_ylabel('CPU (%)', color=orange); cx.set_ylim(0, 100)
ax.grid(axis='y', alpha=0.3)
fig.legend(loc='upper left', bbox_to_anchor=(0.1, 0.9))
ax.set_title('Throughput, 16 cores')
fig.tight_layout(); fig.savefig('throughput.png')

# Test 2: 2 cores, 2 loops, 2 GB, by WebSocket (dashed) and with presence over UDP (solid)
ws_rooms = [1000, 2000, 4000, 5000, 5500, 6000, 8000]
ws_memory = [123, 245, 498, 617, 685, 744, 1000]       # MB at peak, socket buffers included
ws_cpu = [20, 35, 60, 70, 75, 80, 75]                  # % of the machine's 2 cores
udp_rooms = [1000, 2000, 4000, 8000, 12000, 13000, 14000, 16000]
udp_memory = [104, 207, 445, 916, 1375, 1497, 1602, 1863]
udp_cpu = [15, 30, 45, 60, 75, 80, 80, 80]
fig, ax = plt.subplots(figsize=(8, 4.5), dpi=200)
ax.plot(udp_rooms, udp_memory, color=blue, marker='o', lw=2, label='memory, UDP')
ax.plot(ws_rooms, ws_memory, color=blue, marker='o', lw=2, ls='--', mfc='white', label='memory, WebSocket')
ax.set_xlabel('rooms'); ax.set_ylabel('memory (MB)', color=blue); ax.set_ylim(0, 2048)
cx = ax.twinx()
cx.plot(udp_rooms, udp_cpu, color=orange, marker='s', lw=2, label='CPU, UDP')
cx.plot(ws_rooms, ws_cpu, color=orange, marker='s', lw=2, ls='--', mfc='white', label='CPU, WebSocket')
cx.set_ylabel('CPU (%)', color=orange); cx.set_ylim(0, 100)
ax.grid(axis='y', alpha=0.3)
fig.legend(loc='upper left', bbox_to_anchor=(0.1, 0.9), fontsize=10)
ax.set_title('2 GB host')
fig.tight_layout(); fig.savefig('small-host.png')
