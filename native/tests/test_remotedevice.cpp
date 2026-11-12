// Compiled parameter transports on invented device descriptions, compared with the existing encoder.
// No Access resources, device connection or hardware requests are used by these tests.
#include "check.h"
#include "model/remotedevice.h"
#include <array>
#include <climits>
#include <cstring>
#include <type_traits>

using namespace vti;

namespace {
RemoteDevice encoding_device()
{
    const char *xml = R"(<Remotedevice device="Encoding test" version="1">
 <ParameterSets><ParameterSet name="Control">
  <Parameter name="One" minValue="3" maxValue="90" defaultmessage="cc"/>
  <Parameter name="Alias" defaultmessage="cc"/>
  <Parameter name="Pressure" defaultmessage="pressure"/>
  <Parameter name="Mix" defaultmessage="sysex"/>
  <Parameter name="Repeated" defaultmessage="repeated"/>
  <Parameter name="Unmapped" defaultmessage="cc"/>
  <Parameter name="Missing" defaultmessage="absent"/>
  <Parameter name="Unsupported" defaultmessage="dump"/>
 </ParameterSet></ParameterSets>
 <MIDIMessages>
  <MIDIMessage id="cc">
   <byte index="9" content="controller"/>
   <byte index="1" content="controllerid"><parameter mapindex="12" content="Control/One"/>
    <parameter mapindex="12" content="Control/Alias"/><parameter mapindex="23" content="Control/One"/></byte>
   <byte index="2" content="value" mask="1" shift="3"/>
  </MIDIMessage>
  <MIDIMessage id="pressure">
   <byte index="0" content="polypressure"/>
   <byte index="1" content="controllerid"><parameter mapindex="67" content="Control/Pressure"/></byte>
   <byte index="2" content="value"/>
  </MIDIMessage>
  <MIDIMessage id="sysex">
   <byte index="0" content="sysexstart"/><byte index="1" content="byte" tag="125"/>
   <byte index="2" content="deviceid"/><byte index="3" content="part"/>
   <byte index="4" content="controllerid"><parameter mapindex="42" content="Control/Mix"/></byte>
   <byte index="5" content="value"/><byte index="6" content="sysexend"/>
  </MIDIMessage>
  <MIDIMessage id="repeated">
   <byte index="0" content="byte"/><byte index="1" content="byte" tag="300"/>
   <byte index="2" content="controller"/><byte index="3" content="polypressure"/>
   <byte index="4" content="part"/><byte index="5" content="deviceid"/>
   <byte index="6" content="value"/><byte index="7" content="sysexstart"/>
   <byte index="8" content="part"/><byte index="9" content="deviceid"/>
   <byte index="10" content="value"/><byte index="11" content="controller"/>
   <byte index="12" content="controllerid"><parameter mapindex="258" content="Control/Repeated"/></byte>
   <byte index="13" content="polypressure"/><byte index="14" content="byte" tag="-5"/>
   <byte index="15" content="sysexend"/>
  </MIDIMessage>
  <MIDIMessage id="dump">
   <byte index="0" content="controllerid"><parameter mapindex="1" content="Control/Unsupported"/></byte>
   <byte index="1" content="checksum" method="add7" startindex="0" stopindex="0"/>
  </MIDIMessage>
 </MIDIMessages>
</Remotedevice>)";
    RemoteDevice d;
    std::string error;
    CHECK(d.load(std::vector<uint8_t>(xml, xml + std::strlen(xml)), error));
    return d;
}
} // namespace

TEST(compiled_encoding_known_bytes)
{
    auto d = encoding_device();
    auto cc = d.compile_encoding("Control/One");
    CHECK(cc.has_value());
    if (!cc)
        return;
    std::array<uint8_t, 16> out{};
    CHECK_EQ(cc->encode_into(255, 17, out.data(), out.size()), 3u);
    // Last controller map wins; value wraps to 7 bits, not to the parameter's min/max; channel is part & 15.
    CHECK((std::vector<uint8_t>(out.begin(), out.begin() + 3) == std::vector<uint8_t>{0xB1, 23, 127}));
    auto sx = d.compile_encoding("Control/Mix");
    CHECK(sx.has_value());
    if (!sx)
        return;
    CHECK_EQ(sx->encode_into(-1, 16, out.data(), out.size(), 0x25), 7u);
    CHECK((std::vector<uint8_t>(out.begin(), out.begin() + 7) ==
           std::vector<uint8_t>{0xF0, 0x7D, 0x25, 16, 42, 127, 0xF7}));
}

TEST(compiled_encoding_matches_legacy_boundaries)
{
    auto d = encoding_device();
    const int parts[] = {-17, -1, 0, 1, 15, 16, 31, 256};
    const int devices[] = {-1, 0, 0x10, 0x7F, 300};
    const int values[] = {INT_MIN, -257, -129, -1, 0, 1, 90, 127, 128, 255, 256, INT_MAX};
    for (const char *path : {"Control/One", "Control/Alias", "Control/Pressure", "Control/Mix", "Control/Repeated"}) {
        auto compiled = d.compile_encoding(path);
        CHECK(compiled.has_value());
        if (!compiled)
            continue;
        for (int part : parts)
            for (int device : devices)
                for (int value : values) {
                    std::array<uint8_t, 20> a, b;
                    a.fill(0xCC);
                    b.fill(0xCC);
                    const size_t na = d.encode_into(path, value, part, a.data(), a.size(), device);
                    const size_t nb = compiled->encode_into(value, part, b.data(), b.size(), device);
                    CHECK_EQ(na, nb);
                    CHECK(a == b); // bytes beyond the returned length remain untouched too
                    CHECK(d.encode(path, value, part, device) == std::vector<uint8_t>(b.begin(), b.begin() + nb));
                }
    }
}

TEST(compiled_encoding_cap_and_lifetime)
{
    std::optional<ParameterEncoding> compiled;
    {
        auto d = encoding_device();
        compiled = d.compile_encoding("Control/Repeated");
    }
    CHECK(compiled.has_value());
    if (!compiled)
        return;
    static_assert(std::is_trivially_copyable<ParameterEncoding>::value, "RT transport must own only fixed storage");
    static_assert(sizeof(ParameterEncoding) <= 32, "large per-parameter transport table");
    for (size_t cap = 0; cap < 16; cap++) {
        std::array<uint8_t, 20> out;
        out.fill(0xA5);
        CHECK_EQ(compiled->encode_into(100, 3, out.data(), cap), 0u);
        for (uint8_t v : out)
            CHECK_EQ(v, 0xA5);
    }
    std::array<uint8_t, 20> out;
    out.fill(0xA5);
    CHECK_EQ(compiled->encode_into(100, 3, out.data(), 16), 16u);
    CHECK_EQ(out[15], 0xF7);
    CHECK_EQ(out[16], 0xA5);
    CHECK_EQ(compiled->encode_into(0, 0, nullptr, 16), 0u);
}

TEST(compiled_encoding_unsupported_falls_back)
{
    auto d = encoding_device();
    for (const char *path : {"Unknown/Parameter", "Control/Missing", "Control/Unmapped", "Control/Unsupported"})
        CHECK(!d.compile_encoding(path));
    // Transports longer than the audio path's fixed 16-byte event slot must stay on the existing path.
    d.parameters[0].message = "long";
    MidiMessage m;
    m.id = "long";
    m.bytes.resize(17);
    for (auto &b : m.bytes)
        b.content = "value";
    m.bytes[0].content = "controllerid";
    m.bytes[0].controllers.push_back({7, "Control/One"});
    d.messages.push_back(m);
    CHECK(!d.compile_encoding("Control/One"));
    uint8_t out[17]{};
    CHECK_EQ(d.encode_into("Control/One", 3, 0, out, sizeof out), 17u);
}

TEST(compiled_encoding_dynamic_last_byte)
{
    auto d = encoding_device();
    d.parameters[0].message = "last";
    MidiMessage m;
    m.id = "last";
    m.bytes.resize(ParameterEncoding::capacity);
    for (auto &b : m.bytes)
        b.content = "byte";
    m.bytes[0].content = "controllerid";
    m.bytes[0].controllers.push_back({9, "Control/One"});
    d.messages.push_back(m);
    for (const char *kind : {"value", "part", "deviceid", "controller", "polypressure"}) {
        d.messages.back().bytes.back().content = kind;
        auto e = d.compile_encoding("Control/One");
        CHECK(e.has_value());
        if (!e)
            continue;
        std::array<uint8_t, ParameterEncoding::capacity> old{}, fast{};
        CHECK_EQ(d.encode_into("Control/One", 255, 17, old.data(), old.size(), 0x25), old.size());
        CHECK_EQ(e->encode_into(255, 17, fast.data(), fast.size(), 0x25), fast.size());
        CHECK(old == fast); // each dynamic mask must preserve bit 15 at the 16-byte limit
    }
}
