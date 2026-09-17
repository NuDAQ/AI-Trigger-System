#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <string>
#include "cnn_core.h"

namespace nnet {
bool trace_enabled = false;
std::map<std::string, void *> *trace_outputs = nullptr;
size_t trace_type_size = sizeof(double);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    // Independently exercise the actual generated native input type for every
    // raw ADC code, including negative ties and both saturation limits.
    std::ofstream conversion("adc_conversion.txt");
    for (int raw = -2048; raw <= 2047; ++raw) {
        waveform_x8_t word;
        word[0] = static_cast<double>(raw) / 64.0;
        ap_int<10> code = word[0].range(9, 0);
        conversion << code.to_int() << '\n';
    }
    const unsigned windows = std::stoul(argv[1]);
    std::ifstream source("features.f32", std::ios::binary);
    std::ofstream packed("all_input.hex"), expected("all_expected.hex");
    if (!source || !packed || !expected) return 3;
    packed << std::hex << std::setfill('0');
    expected << std::hex << std::setfill('0');
    for (unsigned frame = 0; frame < windows; ++frame) {
        hls::stream<waveform_x8_t> input;
        hls::stream<result_t> output;
        for (unsigned w = 0; w < 32; ++w) {
            waveform_x8_t word;
            for (unsigned s = 0; s < 32; ++s) {
                float sample;
                if (!source.read(reinterpret_cast<char *>(&sample), sizeof(sample))) return 4;
                word[s] = sample; // Native AP_RND / AP_SAT_SYM conversion.
            }
            for (int s = 31; s >= 0; --s) {
                ap_int<10> code = word[s].range(9, 0);
                ap_int<16> slot = code;
                packed << std::setw(4) << slot.range(15, 0).to_uint();
            }
            packed << '\n';
            input.write(word);
        }
        cnn_core(input, output);
        if (!input.empty() || output.size() != 1) return 5;
        result_t score = output.read();
        expected << std::setw(8) << score[0].range(20, 0).to_uint() << '\n';
    }
    char extra;
    if (source.read(&extra, 1)) return 6;
    std::cout << "PASS C++ reference windows=" << windows << '\n';
    return 0;
}
