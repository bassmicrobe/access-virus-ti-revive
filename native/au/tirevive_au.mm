// tirevive_au.mm - the Audio Unit (AUv2) of "TI Revive Virus Control" for Logic Pro / GarageBand: Steinberg's AU
// wrapper (VST3 SDK, MIT; compiled as part of this file) around the VST3 plug-in, which the component carries as
// Contents/Resources/plugin.vst3.
//
// It replaces the classic TI Revive Audio Unit (the bridge that ran the original Access plug-in under Rosetta) and
// has its codes (aumu / VTIr / TIRv), so Logic and GarageBand projects made with "Virus TI (TI Revive)" open with it.
// Those projects stored the plug-in state under the AU preset key "data" (tirbridge_au.cpp); the wrapper expects
// "Processor State". RestoreState translates the old form; the content is the original's state format, which the
// plug-in reads unchanged.
#include "public.sdk/source/vst/auwrapper/auwrapper.mm"
#include "tirevive_au.h"

extern "C" {
__attribute__ ((visibility ("default"))) void* TIReviveVirusControlFactory (const AudioComponentDescription* inDesc)
{
	return Steinberg::Vst::AUFactory<Steinberg::Vst::TIReviveAU>::Factory (inDesc);
}
}
