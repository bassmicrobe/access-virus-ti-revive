// Encoding-only benchmark on an invented model (no Access files, broker or device needed).
// Compare lookup/transport interpretation with a precompiled transport; this is not a plug-in CPU/latency test.
#include "model/remotedevice.h"
#include "access/accessfiles.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace vti;
namespace {
constexpr size_t parameter_count = 384, repetitions = 5;
volatile uint64_t result_sink = 0;
struct Entry {
    std::string path;
    ParameterEncoding encoding;
};
struct Timing {
    double ns_per_message;
    uint64_t checksum;
};

std::string model_xml()
{
    std::string x = "<Remotedevice device=\"Encoding benchmark\"><ParameterSets><ParameterSet name=\"Bench\">";
    for (size_t i = 0; i < parameter_count; i++)
        x += "<Parameter name=\"Parameter" + std::to_string(i) + "\" defaultmessage=\"m" +
             std::to_string(i / 128) + "\"/>";
    x += "</ParameterSet></ParameterSets><MIDIMessages>";
    for (int m = 0; m < 3; m++) {
        x += "<MIDIMessage id=\"m" + std::to_string(m) + "\">";
        if (m == 2)
            x += "<byte content=\"sysexstart\"/><byte content=\"byte\" tag=\"125\"/>"
                 "<byte content=\"deviceid\"/><byte content=\"part\"/>";
        else
            x += m == 0 ? "<byte content=\"controller\"/>" : "<byte content=\"polypressure\"/>";
        x += "<byte content=\"controllerid\">";
        for (int k = 0; k < 128; k++)
            x += "<parameter mapindex=\"" + std::to_string(k) + "\" content=\"Bench/Parameter" +
                 std::to_string(m * 128 + k) + "\"/>";
        x += "</byte><byte content=\"value\"/>";
        if (m == 2)
            x += "<byte content=\"sysexend\"/>";
        x += "</MIDIMessage>";
    }
    return x + "</MIDIMessages></Remotedevice>";
}

Timing measure(const RemoteDevice &d, const std::vector<Entry> &entries, size_t iterations, bool compiled)
{
    uint64_t checksum = 0;
    uint8_t out[ParameterEncoding::capacity];
    const auto start = std::chrono::steady_clock::now();
    for (size_t i = 0; i < iterations; i++) {
        const auto &p = entries[i % entries.size()];
        const int value = (int)((i * 7) & 127), part = (int)((i >> 7) & 15), device = 0x10 + (int)(i & 7);
        const size_t n = compiled ? p.encoding.encode_into(value, part, out, sizeof out, device)
                                  : d.encode_into(p.path, value, part, out, sizeof out, device);
        for (size_t j = 0; j < n; j++)
            checksum += out[j];
    }
    const auto stop = std::chrono::steady_clock::now();
    result_sink = checksum;
    return {std::chrono::duration<double, std::nano>(stop - start).count() / (double)iterations, checksum};
}

int verify_access()
{
    // The user's resources stay in memory only; report counts, never resource bytes, parameter names or paths.
    std::string error;
    auto files = AccessFiles::open("", error);
    if (!files)
        return std::fprintf(stderr, "Access files unavailable; no device was contacted\n"), 77;
    bool ok = true;
    std::puts("{\n  \"scope\": \"read-only local encoder comparison; no device contacted\",\n  \"models\": [");
    bool comma = false;
    for (DeviceType type : {DeviceType::TI, DeviceType::Snow}) {
        if (comma)
            std::puts(",");
        comma = true;
        const char *name = type == DeviceType::TI ? "TI" : "Snow";
        const DeviceFiles own = device_files(type); // require that model's files, not the TI fallback for Snow
        RemoteDevice d;
        std::vector<AutomationEntry> automation;
        if (!d.load(files->get(own.remotedevice), error) ||
            !load_automation(files->get(own.automation), automation, error) || automation.empty()) {
            std::printf("    {\"model\": \"%s\", \"status\": \"resources unavailable or invalid\"}", name);
            ok = false;
            continue;
        }
        size_t supported = 0, fallback = 0, comparisons = 0, mismatch = 0;
        for (const auto &entry : automation) {
            auto e = d.compile_encoding(entry.path);
            if (!e) {
                fallback++;
                continue;
            }
            supported++;
            for (int value = 0; value <= 127; value++) {
                std::array<uint8_t, ParameterEncoding::capacity> old{}, fast{};
                const size_t a = d.encode_into(entry.path, value, entry.part - 1, old.data(), old.size());
                const size_t b = e->encode_into(value, entry.part - 1, fast.data(), fast.size());
                comparisons++;
                mismatch += a != b || old != fast;
            }
        }
        ok &= supported != 0 && mismatch == 0;
        std::printf("    {\"model\": \"%s\", \"automation_entries\": %zu, \"compiled_entries\": %zu, "
                    "\"fallback_entries\": %zu, \"byte_comparisons\": %zu, \"mismatches\": %zu}",
                    name, automation.size(), supported, fallback, comparisons, mismatch);
    }
    std::printf("\n  ],\n  \"pass\": %s\n}\n", ok ? "true" : "false");
    return ok ? 0 : 1;
}
} // namespace

int main(int argc, char **argv)
{
    if (argc == 2 && !std::strcmp(argv[1], "--verify-access")) {
        try {
            return verify_access();
        } catch (...) { // filesystem errors can include private paths; do not put them into a shared report
            return std::fprintf(stderr, "Access resource verification failed; no device was contacted\n"), 1;
        }
    }
    size_t iterations = 1000000;
    if (argc > 2)
        return std::fprintf(stderr, "usage: encodingbench [iterations | --verify-access]\n"), 2;
    if (argc > 1) {
        char *end = nullptr;
        const auto n = std::strtoull(argv[1], &end, 10);
        if (!end || *end || n < 1000 || n > 100000000)
            return std::fprintf(stderr, "usage: encodingbench [iterations: 1000..100000000]\n"), 2;
        iterations = (size_t)n;
    }
    RemoteDevice d;
    const auto xml = model_xml();
    std::string error;
    if (!d.load(std::vector<uint8_t>(xml.begin(), xml.end()), error))
        return std::fprintf(stderr, "%s\n", error.c_str()), 1;
    std::vector<Entry> entries;
    for (const auto &p : d.parameters) {
        auto e = d.compile_encoding(p.path);
        if (!e)
            return std::fprintf(stderr, "could not compile synthetic parameter\n"), 1;
        entries.push_back({p.path, *e});
    }
    measure(d, entries, 10000, false);
    measure(d, entries, 10000, true);
    std::array<double, repetitions> old{}, fast{};
    for (size_t k = 0; k < repetitions; k++) {
        Timing a, b;
        if (k & 1) {
            b = measure(d, entries, iterations, true);
            a = measure(d, entries, iterations, false);
        } else {
            a = measure(d, entries, iterations, false);
            b = measure(d, entries, iterations, true);
        }
        if (a.checksum != b.checksum)
            return std::fprintf(stderr, "encoder outputs differ\n"), 1;
        old[k] = a.ns_per_message;
        fast[k] = b.ns_per_message;
    }
    const auto old_runs = old, fast_runs = fast;
    std::sort(old.begin(), old.end());
    std::sort(fast.begin(), fast.end());
    std::printf("{\n  \"scope\": \"synthetic encoding only; not whole plug-in CPU or USB latency\",\n"
                "  \"parameters\": %zu, \"controllers_per_template\": 128, \"iterations_per_run\": %zu,\n"
                "  \"repetitions\": %zu, \"compiled_record_bytes\": %zu,\n"
                "  \"legacy_median_ns\": %.3f, \"compiled_median_ns\": %.3f, \"speedup\": %.3f,\n",
                entries.size(), iterations, repetitions, sizeof(ParameterEncoding), old[repetitions / 2],
                fast[repetitions / 2], old[repetitions / 2] / fast[repetitions / 2]);
    auto runs = [](const char *key, const std::array<double, repetitions> &r, bool comma) {
        std::printf("  \"%s\": [", key);
        for (size_t k = 0; k < r.size(); k++)
            std::printf("%s%.3f", k ? ", " : "", r[k]);
        std::printf("]%s\n", comma ? "," : "");
    };
    runs("legacy_runs_ns", old_runs, true);
    runs("compiled_runs_ns", fast_runs, false);
    std::puts("}");
    return 0;
}
