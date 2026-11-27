// sim_main.cpp - Verilator whole-system simulation of nexys_a7_top.
// Plays a button/switch script and writes VGA frames as PPM pictures.
//   usage: Vnexys_a7_top <script.txt> <outdir>
// script lines:  <frame> <command> [arg]
//   press U|D|L|R|C <frames>   hold a button for N frames (C held >= 48 frames = "back")
//   tap C                      short BTNC press (6 frames)
//   sw <n> 0|1                 set switch n
//   reset                      press CPU RESET for 200 clock cycles (switches are read again at boot)
//   shot <name>                save the NEXT complete frame as <outdir>/<name>.ppm
//   end                        stop
#include "Vnexys_a7_top.h"
#include "Vnexys_a7_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

struct Cmd { long frame; std::string op, a, b; };

int main(int argc, char** argv) {
    long reset_frame = -1;
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s script outdir\n", argv[0]); return 1; }
    std::vector<Cmd> cmds;
    std::ifstream in(argv[1]);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line); Cmd c; ss >> c.frame >> c.op >> c.a >> c.b; cmds.push_back(c);
    }
    std::string outdir = argv[2];
    Vnexys_a7_top* top = new Vnexys_a7_top;
    top->CPU_RESETN = 0; top->SW = 0;
    top->BTNC = top->BTNU = top->BTND = top->BTNL = top->BTNR = 0;
    std::map<char, long> hold_until;            // button -> frame number when released
    static unsigned char img[480][640][3];
    long frame = 0; size_t ci = 0;
    std::vector<std::string> pending_shots, active_shots;
    int last_vs = 1; long cycles = 0;
    int prev_ce_hc = -1;
    bool done = false;
    while (!done && !Verilated::gotFinish()) {
        top->CLK100MHZ = 0; top->eval();
        top->CLK100MHZ = 1; top->eval();
        cycles++;
        if (reset_frame > 0 && cycles == reset_frame) top->CPU_RESETN = 1;
        if (cycles == 200) top->CPU_RESETN = 1;
        // sample the output pixel: the output register shows pixel (hc-1, vc) of the previous slot
        auto* r = top->rootp;
        int phase = r->nexys_a7_top__DOT__u_video__DOT__u_tim__DOT__phase;
        if (phase == 0) {
            int hc = r->nexys_a7_top__DOT__u_video__DOT__u_tim__DOT__hc;
            int vc = r->nexys_a7_top__DOT__u_video__DOT__u_tim__DOT__vc;
            int x = hc - 1, y = vc;
            if (hc == 0) { x = 799; y = vc ? vc - 1 : 524; }
            if (x >= 0 && x < 640 && y >= 0 && y < 480) {
                img[y][x][0] = top->VGA_R * 17; img[y][x][1] = top->VGA_G * 17; img[y][x][2] = top->VGA_B * 17;
            }
        }
        // frame boundary at the falling edge of VSYNC
        int vs = top->VGA_VS;
        if (last_vs == 1 && vs == 0) {
            for (auto& n : active_shots) {
                std::string fn = outdir + "/" + n + ".ppm";
                FILE* f = fopen(fn.c_str(), "wb");
                fprintf(f, "P6 640 480 255\n"); fwrite(img, 1, sizeof(img), f); fclose(f);
                printf("frame %ld: wrote %s\n", frame, fn.c_str());
            }
            active_shots = pending_shots; pending_shots.clear();
            frame++;
            // release buttons
            for (auto& kv : hold_until) if (kv.second == frame) {
                switch (kv.first) { case 'U': top->BTNU = 0; break; case 'D': top->BTND = 0; break;
                    case 'L': top->BTNL = 0; break; case 'R': top->BTNR = 0; break; case 'C': top->BTNC = 0; break; }
            }
            while (ci < cmds.size() && cmds[ci].frame <= frame) {
                Cmd& c = cmds[ci++];
                if (c.op == "press" || c.op == "tap") {
                    long n = (c.op == "tap") ? 6 : atol(c.b.c_str());
                    char b = c.a[0];
                    switch (b) { case 'U': top->BTNU = 1; break; case 'D': top->BTND = 1; break;
                        case 'L': top->BTNL = 1; break; case 'R': top->BTNR = 1; break; case 'C': top->BTNC = 1; break; }
                    hold_until[b] = frame + n;
                } else if (c.op == "sw") {
                    int n = atoi(c.a.c_str()); int v = atoi(c.b.c_str());
                    if (v) top->SW |= (1 << n); else top->SW &= ~(1 << n);
                } else if (c.op == "reset") {           // CPU_RESETN low until the next frame
                    top->CPU_RESETN = 0; reset_frame = cycles + 200;
                } else if (c.op == "shot") {
                    pending_shots.push_back(c.a);
                } else if (c.op == "end") {
                    done = true;
                }
            }
        }
        last_vs = vs;
    }
    printf("simulated %ld frames, %ld cycles\n", frame, cycles);
    top->final();
    delete top;
    return 0;
}
