// Nerd mode's diagnostics (src/cc/diag) below temporary platform-specific application folders - never the user's
// real plug-in folder: the switches, log tails, anonymizing (home folder, user name) and the bug-report file.
#include "check.h"
#include "cc/diag.h"
#include "model/utf8.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif
using namespace vti::cc;
namespace fs = std::filesystem;

namespace {
struct Home {
    struct Saved {
        std::string key, value;
        bool had;
    };
    std::vector<Saved> saved;
    fs::path dir;
    void set(const char *key, const std::string &value)
    {
#ifdef _WIN32
        saved.push_back({key, vti::u8env(key), _wgetenv(vti::widen(key).c_str()) != nullptr});
        _wputenv_s(vti::widen(key).c_str(), vti::widen(value).c_str());
#else
        const char *old = getenv(key);
        saved.push_back({key, old ? old : "", old != nullptr});
        setenv(key, value.c_str(), 1);
#endif
    }
    explicit Home(const char *user)
    {
        static unsigned sequence = 0; // nested fixtures must not remove the outer fixture's folder
#ifdef _WIN32
        const int pid = _getpid();
#else
        const int pid = getpid();
#endif
        dir = fs::temp_directory_path() / ("vtitests-diag-" + std::to_string(pid) + "-" + std::to_string(++sequence));
        fs::remove_all(dir);
        fs::create_directories(dir);
#ifdef _WIN32
        fs::create_directories(dir / "tmp");
        set("USERPROFILE", vti::u8str(dir));
        set("USERNAME", user);
        set("LOCALAPPDATA", vti::u8str(dir / "LocalAppData"));
        set("TEMP", vti::u8str(dir / "tmp"));
#else
        set("HOME", vti::u8str(dir));
        set("USER", user);
#endif
    }
    fs::path plugin_folder() const
    {
#ifdef _WIN32
        return dir / "LocalAppData/virus-ti-native";
#elif defined(__APPLE__)
        return dir / "Library/Application Support/virus-ti-native";
#else
        return dir / ".local/share/virus-ti-native";
#endif
    }
    ~Home()
    {
        for (const auto &s : saved) {
#ifdef _WIN32
            _wputenv_s(vti::widen(s.key).c_str(), s.had ? vti::widen(s.value).c_str() : L"");
#else
            s.had ? setenv(s.key.c_str(), s.value.c_str(), 1) : unsetenv(s.key.c_str());
#endif
        }
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
};

const char *platform_name()
{
#ifdef _WIN32
    return "Windows";
#elif defined(__APPLE__)
    return "macOS";
#else
    return "Linux";
#endif
}
} // namespace

TEST(diag_switch_and_paths)
{
    Home h("vtester");
    const fs::path folder = h.plugin_folder();
    CHECK(vti::u8path(plugin_dir()).lexically_normal() == folder.lexically_normal());
    CHECK(vti::u8path(plugin_log_path()).lexically_normal() == (folder / "diag.log").lexically_normal());
    // on by default since 0.8.41 (user 2026-11-10: reports without the log kept coming); diag.off switches it off
    CHECK(plugin_log_enabled());
    std::string err;
    CHECK(set_plugin_log(false, err) && !plugin_log_enabled()); // creates the folder too
    CHECK(fs::exists(folder / "diag.off"));
    CHECK(set_plugin_log(false, err)); // again: harmless
    CHECK(set_plugin_log(true, err) && plugin_log_enabled());
    CHECK(!fs::exists(folder / "diag.off"));
    CHECK(set_plugin_log(true, err)); // already on
    // an old diag.on (the switch before 0.8.41) changes nothing, and switching off removes it
    std::ofstream(folder / "diag.on").put('\n');
    CHECK(plugin_log_enabled());
    CHECK(set_plugin_log(false, err) && !plugin_log_enabled());
    CHECK(!fs::exists(folder / "diag.on"));
    CHECK(set_plugin_log(true, err));
#ifdef _WIN32
    CHECK(vti::u8path(broker_log_location()).lexically_normal() == (h.dir / "tmp/vtibroker.log").lexically_normal());
#elif defined(__APPLE__)
    CHECK(broker_log_location() == "/tmp/tirevive-vtibroker.log");
#else
    CHECK(broker_log_location() == "journalctl --user -u tirevive-broker");
#endif
    (void)broker_log_tail(5); // the platform's broker log: read-only, may be empty (CI)
}

// the Control Center's options (nerd mode): flag files in the plug-in's folder, read when a plug-in instance starts
TEST(diag_plugin_options)
{
    Home h("vtester");
    const auto &opts = plugin_options();
    CHECK(opts.size() == 6);
    // plugin-log (0.8.41): the plug-in's log for bug reports, ON by default; diag.off switches it off, so the plug-in's
    // own Options page can do it (the user is told on What's New and the welcome page)
    CHECK(std::string(opts[5].name) == "plugin-log" && std::string(opts[5].file) == "diag.off");
    CHECK(opts[5].default_on && plugin_option("plugin-log") == plugin_log_enabled());
    // low-latency (E496, 0.8.41): the experimental lower lead, OFF by default; low-latency.on switches it on
    CHECK(std::string(opts[4].name) == "low-latency" && std::string(opts[4].file) == "low-latency.on");
    CHECK(!opts[4].default_on);
    CHECK(!plugin_option("low-latency"));
    // the Control Center's Options page (0.8.41) shows a title and a one-line explanation per option
    for (auto &o : opts)
        CHECK(o.title && *o.title && o.hint && *o.hint);
    // slip-restart (E488, 0.8.41): on by default, the Control Center switch writes slip-restart.off
    CHECK(std::string(opts[3].name) == "slip-restart" && std::string(opts[3].file) == "slip-restart.off");
    CHECK(opts[3].default_on);
    CHECK(plugin_option("slip-restart"));
    CHECK(std::string(opts[0].name) == "outdelay-changes" && std::string(opts[0].file) == "outdelay-changes.on");
    CHECK(std::string(opts[1].name) == "timing-classic" && std::string(opts[1].file) == "timing-classic.on");
    // live-notes is on by default since 0.8.39 (the original's VST3 does it always, E400/E402; user 2026-11-08): its
    // file switches it OFF
    CHECK(std::string(opts[2].name) == "live-notes" && std::string(opts[2].file) == "live-notes.off");
    CHECK(opts[2].default_on && !opts[0].default_on && !opts[1].default_on);
    CHECK(plugin_option("live-notes")); // on without any file
    std::string e0;
    CHECK(set_plugin_option("live-notes", false, e0) && !plugin_option("live-notes"));
    CHECK(fs::exists(h.plugin_folder() / "live-notes.off"));
    CHECK(set_plugin_option("live-notes", true, e0) && plugin_option("live-notes"));
    CHECK(!fs::exists(h.plugin_folder() / "live-notes.off"));
    CHECK(!plugin_option("outdelay-changes"));
    std::string err;
    CHECK(set_plugin_option("outdelay-changes", true, err) && plugin_option("outdelay-changes"));
    CHECK(fs::exists(h.plugin_folder() / "outdelay-changes.on"));
    CHECK(!plugin_option("timing-classic")); // independent
    CHECK(set_plugin_option("outdelay-changes", false, err) && !plugin_option("outdelay-changes"));
    CHECK(!set_plugin_option("no-such-option", true, err) && !err.empty());
    CHECK(!plugin_option("no-such-option"));
}

TEST(diag_tail_file)
{
    Home h("vtester");
    CHECK(tail_file(vti::u8str(h.dir / "missing.log"), 10).empty());
    fs::path small = h.dir / "small.log";
    std::ofstream(small) << "one\r\ntwo\nthree\n";
    auto t = tail_file(vti::u8str(small), 2);
    CHECK(t.size() == 2 && t[0] == "two" && t[1] == "three"); // the last n, CR removed
    CHECK(tail_file(vti::u8str(small), 10).size() == 3 && tail_file(vti::u8str(small), 10)[0] == "one");
    // a long log: only its end is read, the partial first line of that window is dropped
    fs::path big = h.dir / "big.log";
    {
        std::ofstream o(big);
        for (int i = 0; i < 20000; i++)
            o << "line " << i << " " << std::string(50, 'x') << "\n";
    }
    auto b = tail_file(vti::u8str(big), 3);
    CHECK(b.size() == 3 && b[2].rfind("line 19999 ", 0) == 0 && b[0].rfind("line 19997 ", 0) == 0);
}

TEST(diag_anonymize)
{
    Home h("vtester");
    const std::string home = vti::u8str(h.dir);
    std::string alt = home; // the same path with the other kind of slashes
    for (auto &c : alt)
        c = c == '/' ? '\\' : c == '\\' ? '/' : c;
    std::string in = "cache " + home + "/cache, wine " + alt + "\\drive_c, owner vtester, other text";
    std::string out = anonymize(in);
    CHECK(out.find(home) == std::string::npos && out.find(alt) == std::string::npos);
    CHECK(out.find("~/cache") != std::string::npos && out.find("~\\drive_c") != std::string::npos);
    CHECK(out.find("owner <user>") != std::string::npos && out.find("other text") != std::string::npos);
    {
        Home shortname("ab"); // a very short user name is left alone (it would hit ordinary words)
        CHECK(anonymize("about ab").find("<user>") == std::string::npos);
    }
}

// the log is on for everyone since 0.8.41, so it must not grow without end: over the limit diag.log becomes diag.log.1
// (an older .1 is replaced), at most about two limits on disk
TEST(diag_rotate_log)
{
    Home h("vtester");
    fs::path log = h.dir / "diag.log", old = h.dir / "diag.log.1";
    CHECK(!rotate_log(vti::u8str(log), 100)); // missing: nothing to do
    std::ofstream(log) << std::string(100, 'a');
    CHECK(!rotate_log(vti::u8str(log), 100) && fs::exists(log)); // at the limit: kept
    std::ofstream(log, std::ios::app) << "b";
    CHECK(rotate_log(vti::u8str(log), 100) && !fs::exists(log) && fs::file_size(old) == 101);
    std::ofstream(log) << std::string(150, 'c');
    CHECK(rotate_log(vti::u8str(log), 100) && fs::file_size(old) == 150); // the older .1 is replaced
    CHECK(kPluginLogLimit >= 1000000 && kPluginLogLimit <= 8000000);
}

TEST(diag_collect_logs)
{
    Home h("vtester");
    std::string err;
    CHECK(set_plugin_log(true, err));
    fs::create_directories(vti::u8path(plugin_dir())); // "on" writes no file since 0.8.41; the plug-in makes its folder itself
    {
        std::ofstream o(vti::u8path(plugin_log_path()));
        o << "Virus TI native: cache " << vti::u8str(h.dir) << "/x\n" << "Virus ready after 3.8 s\n";
    }
    fs::path out = h.dir / "report.txt";
    CHECK(collect_logs(vti::u8str(out), "0.0.1", err));
    std::ifstream f(out);
    std::string all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    f.close();
    CHECK(all.find("TI Revive logs") == 0 &&
          all.find(std::string("Control Center 0.0.1 on ") + platform_name()) != std::string::npos);
    CHECK(all.find("Plug-in log ON") != std::string::npos && all.find("Virus ready after 3.8 s") != std::string::npos);
    CHECK(all.find(vti::u8str(h.dir)) == std::string::npos && all.find("cache ~/x") != std::string::npos);
    CHECK(all.find("--- broker log") != std::string::npos);
    // right after a rotation diag.log is short: the end of diag.log.1 comes first, so the report keeps its context
    {
        std::ofstream(vti::u8path(plugin_log_path() + ".1")) << "older line\n";
        std::ofstream(vti::u8path(plugin_log_path())) << "newer line\n";
        CHECK(collect_logs(vti::u8str(out), "0.0.1", err));
        std::ifstream g(out);
        std::string r((std::istreambuf_iterator<char>(g)), std::istreambuf_iterator<char>());
        const size_t a = r.find("older line"), b = r.find("newer line");
        CHECK(a != std::string::npos && b != std::string::npos && a < b);
    }
    // switched off: the header says how to switch it on again
    CHECK(set_plugin_log(false, err) && collect_logs(vti::u8str(out), "0.0.1", err));
    {
        std::ifstream g(out);
        std::string r((std::istreambuf_iterator<char>(g)), std::istreambuf_iterator<char>());
        CHECK(r.find("Plug-in log OFF (switch it on on the Options page") != std::string::npos);
    }
    // a folder as the target: cannot be written
    err.clear();
    CHECK(!collect_logs(vti::u8str(h.dir), "0.0.1", err) && !err.empty());
}
