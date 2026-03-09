// =============================================================================
// visualize_waveforms.C
// CERN ROOT macro to visualize waveform data from the AI Trigger System.
//
// Run from data/analysis/ directory:
//   root -l -b -q visualize_waveforms.C          // batch: save .pdf + .root
//   root -l 'visualize_waveforms.C(true)'        // interactive browser
//
// Output (in data/analysis/):
//   waveforms.pdf   -- all plots in a multi-page PDF
//   waveforms.root  -- all histograms and graphs saved as ROOT objects
//
// Interactive functions (after loading with interactive=true):
//   DrawEvent(n)        -- draw event n
//   NextEvent()         -- next event
//   PrevEvent()         -- previous event
//   NextSignal()        -- next signal event
//   PrevSignal()        -- previous signal event
// =============================================================================

#include <fstream>
#include <string>
#include <algorithm>

// ---- Constants --------------------------------------------------------------
static const int kNEvents  = 1000;
static const int kNSamples = 256;
static const int kNCh      = 4;

static const char* kEvFile  = "../real_events.hex";
static const char* kLblFile = "../real_labels.hex";
static const char* kOutPDF  = "waveforms.pdf";
static const char* kOutRoot = "waveforms.root";

// ---- Globals ----------------------------------------------------------------
static double   gWave[kNEvents][kNCh][kNSamples];
static int      gLabel[kNEvents];
static bool     gLoaded       = false;
static int      gCurrentEvent = 0;
static TCanvas* gCanvasWave   = nullptr;

static const char* kChName[kNCh]  = {"Ch 0", "Ch 1", "Ch 2", "Ch 3"};
static const int   kChColor[kNCh] = {kBlue+1, kRed+1, kGreen+2, kOrange+1};

// ---- Helpers ----------------------------------------------------------------

inline double Decode12(int v) {
    if (v >= 2048) v -= 4096;
    return v / 64.0;
}

int CountLabel(int val) {
    int n = 0;
    for (int i = 0; i < kNEvents; ++i) if (gLabel[i] == val) ++n;
    return n;
}

// Find the idx-th event (0-based) that has the given label; returns -1 if not found
int FindNthEvent(int label, int idx) {
    int count = 0;
    for (int ev = 0; ev < kNEvents; ++ev)
        if (gLabel[ev] == label && count++ == idx) return ev;
    return -1;
}

// ---- Data loading -----------------------------------------------------------

bool LoadData() {
    if (gLoaded) return true;

    std::ifstream fevt(kEvFile);
    if (!fevt.is_open()) {
        Error("LoadData", "Cannot open: %s  (run from data/analysis/)", kEvFile);
        return false;
    }
    std::string line;
    for (int ev = 0; ev < kNEvents; ++ev) {
        for (int t = 0; t < kNSamples; ++t) {
            if (!std::getline(fevt, line) || line.size() < 12) {
                Error("LoadData", "EOF at event %d sample %d", ev, t);
                return false;
            }
            // Format: {ch3:03X}{ch2:03X}{ch1:03X}{ch0:03X}
            int ch3 = (int)strtol(line.substr(0,3).c_str(), nullptr, 16);
            int ch2 = (int)strtol(line.substr(3,3).c_str(), nullptr, 16);
            int ch1 = (int)strtol(line.substr(6,3).c_str(), nullptr, 16);
            int ch0 = (int)strtol(line.substr(9,3).c_str(), nullptr, 16);
            gWave[ev][0][t] = Decode12(ch0);
            gWave[ev][1][t] = Decode12(ch1);
            gWave[ev][2][t] = Decode12(ch2);
            gWave[ev][3][t] = Decode12(ch3);
        }
    }
    fevt.close();

    std::ifstream flbl(kLblFile);
    if (!flbl.is_open()) {
        Error("LoadData", "Cannot open: %s", kLblFile);
        return false;
    }
    for (int ev = 0; ev < kNEvents; ++ev) {
        if (!std::getline(flbl, line)) {
            Error("LoadData", "EOF at label %d", ev);
            return false;
        }
        gLabel[ev] = (int)strtol(line.c_str(), nullptr, 16);
    }
    flbl.close();

    gLoaded = true;
    Printf("==> Loaded %d events: %d signal (1), %d background (0)",
           kNEvents, CountLabel(1), CountLabel(0));
    return true;
}

// ---- Per-event waveform canvas ----------------------------------------------

// Returns a newly-created canvas (caller owns it / it goes to gCanvasWave)
TCanvas* MakeEventCanvas(int evIdx) {
    if (!gCanvasWave) {
        gCanvasWave = new TCanvas("cWave", "AI Trigger System -- Waveform Viewer",
                                  100, 100, 1280, 900);
        gCanvasWave->Divide(2, 2, 0.002, 0.002);
    }

    const char* lblStr = (gLabel[evIdx] == 1)
        ? "#color[2]{SIGNAL (1)}" : "#color[4]{Background (0)}";

    for (int ch = 0; ch < kNCh; ++ch) {
        TVirtualPad* pad = gCanvasWave->cd(ch + 1);
        pad->Clear();
        pad->SetGrid();
        pad->SetLeftMargin(0.13);
        pad->SetBottomMargin(0.12);

        auto* gr = new TGraph(kNSamples);
        gr->SetName(Form("grEv%d_Ch%d", evIdx, ch));
        for (int t = 0; t < kNSamples; ++t)
            gr->SetPoint(t, t, gWave[evIdx][ch][t]);

        gr->SetTitle(Form("Event %d | %s | Label: %s",
                          evIdx, kChName[ch], lblStr));
        gr->GetXaxis()->SetTitle("Time Sample");
        gr->GetXaxis()->SetTitleOffset(1.1);
        gr->GetYaxis()->SetTitle("Amplitude (ADC counts)");
        gr->GetYaxis()->SetTitleOffset(1.5);
        gr->SetLineColor(kChColor[ch]);
        gr->SetLineWidth(2);
        gr->Draw("AL");
    }

    // Overall title on the canvas margin
    gCanvasWave->cd(0);
    TLatex* ltx = new TLatex(0.5, 0.987,
        Form("Event %d / %d   |   Label: %s",
             evIdx, kNEvents-1,
             gLabel[evIdx] == 1 ? "SIGNAL" : "Background"));
    ltx->SetNDC();
    ltx->SetTextAlign(23);
    ltx->SetTextSize(0.022);
    ltx->SetTextFont(62);
    ltx->Draw();

    gCanvasWave->Update();
    return gCanvasWave;
}

void DrawEvent(int evIdx = 0) {
    if (!LoadData()) return;
    if (evIdx < 0 || evIdx >= kNEvents) {
        Warning("DrawEvent", "Event %d out of range [0, %d)", evIdx, kNEvents);
        return;
    }
    gCurrentEvent = evIdx;
    MakeEventCanvas(evIdx);
    Printf("Event %d | Label: %d (%s)",
           evIdx, gLabel[evIdx], gLabel[evIdx] == 1 ? "SIGNAL" : "Background");
}

// ---- Navigation -------------------------------------------------------------

void NextEvent()  { DrawEvent((gCurrentEvent + 1) % kNEvents); }
void PrevEvent()  { DrawEvent((gCurrentEvent - 1 + kNEvents) % kNEvents); }

void NextSignal() {
    for (int i = 1; i <= kNEvents; ++i) {
        int ev = (gCurrentEvent + i) % kNEvents;
        if (gLabel[ev] == 1) { DrawEvent(ev); return; }
    }
}
void PrevSignal() {
    for (int i = 1; i <= kNEvents; ++i) {
        int ev = (gCurrentEvent - i + kNEvents) % kNEvents;
        if (gLabel[ev] == 1) { DrawEvent(ev); return; }
    }
}

// ---- Overlay canvas ---------------------------------------------------------

TCanvas* MakeOverlayCanvas(int nOverlay = 20) {
    auto* cOv = new TCanvas("cOverlayAll",
                            "Waveform Overlay -- All Channels",
                            200, 150, 1280, 900);
    cOv->Divide(2, 2, 0.002, 0.002);

    // Global y-range
    double ymin =  1e9, ymax = -1e9;
    for (int ev = 0; ev < kNEvents; ++ev)
        for (int ch = 0; ch < kNCh; ++ch)
            for (int t = 0; t < kNSamples; ++t) {
                ymin = std::min(ymin, gWave[ev][ch][t]);
                ymax = std::max(ymax, gWave[ev][ch][t]);
            }
    double margin = (ymax - ymin) * 0.06;

    for (int ch = 0; ch < kNCh; ++ch) {
        TVirtualPad* pad = cOv->cd(ch + 1);
        pad->SetGrid();
        pad->SetLeftMargin(0.13);
        pad->SetBottomMargin(0.12);

        TH1F* hFrame = pad->DrawFrame(0, ymin - margin,
                                      kNSamples - 1, ymax + margin);
        hFrame->SetTitle(Form("%s | Signal (red) vs Background (blue)"
                              ";Time Sample;Amplitude (ADC counts)", kChName[ch]));
        hFrame->GetXaxis()->SetTitleOffset(1.1);
        hFrame->GetYaxis()->SetTitleOffset(1.5);

        int nSig = 0, nBkg = 0;
        for (int ev = 0; ev < kNEvents; ++ev) {
            bool isSig = (gLabel[ev] == 1);
            if ( isSig && nSig >= nOverlay) continue;
            if (!isSig && nBkg >= nOverlay) continue;

            auto* gr = new TGraph(kNSamples);
            for (int t = 0; t < kNSamples; ++t)
                gr->SetPoint(t, t, gWave[ev][ch][t]);
            gr->SetLineColor(isSig ? kRed : kBlue);
            gr->SetLineWidth(1);
            gr->Draw("L SAME");
            if (isSig) ++nSig; else ++nBkg;
        }

        if (ch == 0) {
            TLegend* leg = new TLegend(0.65, 0.78, 0.95, 0.93);
            TGraph* gS = new TGraph(); gS->SetLineColor(kRed);  gS->SetLineWidth(2);
            TGraph* gB = new TGraph(); gB->SetLineColor(kBlue); gB->SetLineWidth(2);
            leg->AddEntry(gS, Form("Signal (%d shown)",     nSig), "L");
            leg->AddEntry(gB, Form("Background (%d shown)", nBkg), "L");
            leg->SetBorderSize(1);
            leg->SetTextSize(0.042);
            leg->Draw();
        }
    }
    cOv->Update();
    return cOv;
}

// ---- Summary canvas ---------------------------------------------------------

TCanvas* MakeSummaryCanvas() {
    auto* cSum = new TCanvas("cSummary", "AI Trigger System -- Data Summary",
                             300, 200, 1280, 900);
    cSum->Divide(3, 2, 0.003, 0.003);

    // Pad 1: label bar chart
    {
        cSum->cd(1);
        gPad->SetGrid();
        gPad->SetLeftMargin(0.15);
        int nSig = CountLabel(1), nBkg = CountLabel(0);
        auto* hLbl = new TH1I("hLabel", "Label Distribution;Label;Count", 2, 0, 2);
        hLbl->SetBinContent(1, nBkg);
        hLbl->SetBinContent(2, nSig);
        hLbl->GetXaxis()->SetBinLabel(1, "0  Background");
        hLbl->GetXaxis()->SetBinLabel(2, "1  Signal");
        hLbl->SetFillColor(kAzure + 7);
        hLbl->SetLineColor(kBlue + 2);
        hLbl->SetBarWidth(0.5);
        hLbl->SetBarOffset(0.25);
        hLbl->Draw("B TEXT0");
        TLatex lt;
        lt.SetNDC(); lt.SetTextSize(0.040); lt.SetTextAlign(22);
        lt.DrawLatex(0.5, 0.88,
            Form("Signal fraction: %.1f%%", 100.0 * nSig / kNEvents));
    }

    // Pads 2-5: amplitude distributions per channel (signal vs background)
    const int   kNBins = 120;
    const double kAmpMin = -35.0, kAmpMax = 35.0;

    for (int ch = 0; ch < kNCh; ++ch) {
        cSum->cd(ch + 2);
        gPad->SetGrid();
        gPad->SetLeftMargin(0.14);

        auto* hSig = new TH1D(Form("hSig_Ch%d", ch),
                              Form("%s Amplitude;Amplitude (ADC counts);Norm. counts",
                                   kChName[ch]),
                              kNBins, kAmpMin, kAmpMax);
        auto* hBkg = new TH1D(Form("hBkg_Ch%d", ch), "",
                              kNBins, kAmpMin, kAmpMax);

        for (int ev = 0; ev < kNEvents; ++ev)
            for (int t = 0; t < kNSamples; ++t) {
                if (gLabel[ev] == 1) hSig->Fill(gWave[ev][ch][t]);
                else                 hBkg->Fill(gWave[ev][ch][t]);
            }

        hSig->Scale(1.0 / hSig->Integral());
        hBkg->Scale(1.0 / hBkg->Integral());

        double ymax = std::max(hSig->GetMaximum(), hBkg->GetMaximum()) * 1.18;

        hBkg->SetMaximum(ymax);
        hBkg->SetLineColor(kBlue+1);  hBkg->SetLineWidth(2);
        hBkg->SetFillColorAlpha(kBlue+1, 0.25);
        hBkg->Draw("HIST");

        hSig->SetLineColor(kRed+1);   hSig->SetLineWidth(2);
        hSig->SetFillColorAlpha(kRed+1, 0.25);
        hSig->Draw("HIST SAME");

        if (ch == 0) {
            TLegend* leg = new TLegend(0.60, 0.76, 0.95, 0.93);
            leg->AddEntry(hSig, "Signal",     "LF");
            leg->AddEntry(hBkg, "Background", "LF");
            leg->SetBorderSize(1);
            leg->SetTextSize(0.044);
            leg->Draw();
        }
    }

    // Pad 6: channel-averaged mean waveform per class
    {
        cSum->cd(6);
        gPad->SetGrid();
        gPad->SetLeftMargin(0.14);

        int nSig = CountLabel(1), nBkg = CountLabel(0);
        auto* grSig = new TGraph(kNSamples);
        auto* grBkg = new TGraph(kNSamples);
        grSig->SetName("grMeanSig");
        grBkg->SetName("grMeanBkg");

        for (int t = 0; t < kNSamples; ++t) {
            double sumSig = 0, sumBkg = 0;
            for (int ev = 0; ev < kNEvents; ++ev) {
                double val = 0;
                for (int ch = 0; ch < kNCh; ++ch) val += gWave[ev][ch][t];
                val /= kNCh;
                if (gLabel[ev] == 1) sumSig += val;
                else                 sumBkg += val;
            }
            grSig->SetPoint(t, t, (nSig > 0) ? sumSig / nSig : 0.0);
            grBkg->SetPoint(t, t, (nBkg > 0) ? sumBkg / nBkg : 0.0);
        }

        grSig->SetTitle("Mean Waveform (ch-averaged)"
                        ";Time Sample;Mean Amplitude (ADC counts)");
        grSig->SetLineColor(kRed+1);  grSig->SetLineWidth(2);
        grBkg->SetLineColor(kBlue+1); grBkg->SetLineWidth(2);
        grSig->GetYaxis()->SetTitleOffset(1.5);

        grSig->Draw("AL");
        grBkg->Draw("L SAME");

        TLegend* leg = new TLegend(0.60, 0.76, 0.95, 0.93);
        leg->AddEntry(grSig, "Mean Signal",     "L");
        leg->AddEntry(grBkg, "Mean Background", "L");
        leg->SetBorderSize(1);
        leg->SetTextSize(0.044);
        leg->Draw();
    }

    cSum->Update();
    return cSum;
}

// ---- Example event canvases (4 signal + 4 background) -----------------------

// Returns a canvas showing one event from each class side-by-side per channel
TCanvas* MakeExampleCanvas(int sigIdx, int bkgIdx, int canvasIdx) {
    int sigEv = FindNthEvent(1, sigIdx);
    int bkgEv = FindNthEvent(0, bkgIdx);
    if (sigEv < 0 || bkgEv < 0) return nullptr;

    auto* c = new TCanvas(Form("cExample_%d", canvasIdx),
                          Form("Example Events (sig=%d, bkg=%d)", sigEv, bkgEv),
                          400, 150, 1280, 900);
    c->Divide(2, 2, 0.002, 0.002);

    for (int ch = 0; ch < kNCh; ++ch) {
        TVirtualPad* pad = c->cd(ch + 1);
        pad->SetGrid();
        pad->SetLeftMargin(0.13);
        pad->SetBottomMargin(0.12);

        // Determine common y-range for this channel
        double ymin =  1e9, ymax = -1e9;
        for (int t = 0; t < kNSamples; ++t) {
            ymin = std::min({ymin, gWave[sigEv][ch][t], gWave[bkgEv][ch][t]});
            ymax = std::max({ymax, gWave[sigEv][ch][t], gWave[bkgEv][ch][t]});
        }
        double mg = (ymax - ymin) * 0.1;

        TH1F* hFrame = pad->DrawFrame(0, ymin - mg, kNSamples - 1, ymax + mg);
        hFrame->SetTitle(Form("%s;Time Sample;Amplitude (ADC counts)", kChName[ch]));
        hFrame->GetXaxis()->SetTitleOffset(1.1);
        hFrame->GetYaxis()->SetTitleOffset(1.5);

        // Signal waveform
        auto* grS = new TGraph(kNSamples);
        for (int t = 0; t < kNSamples; ++t)
            grS->SetPoint(t, t, gWave[sigEv][ch][t]);
        grS->SetLineColor(kRed+1); grS->SetLineWidth(2);
        grS->Draw("L SAME");

        // Background waveform
        auto* grB = new TGraph(kNSamples);
        for (int t = 0; t < kNSamples; ++t)
            grB->SetPoint(t, t, gWave[bkgEv][ch][t]);
        grB->SetLineColor(kBlue+1); grB->SetLineWidth(2);
        grB->Draw("L SAME");

        if (ch == 0) {
            TLegend* leg = new TLegend(0.62, 0.78, 0.95, 0.93);
            leg->AddEntry(grS, Form("Signal (ev %d)",     sigEv), "L");
            leg->AddEntry(grB, Form("Background (ev %d)", bkgEv), "L");
            leg->SetBorderSize(1); leg->SetTextSize(0.040);
            leg->Draw();
        }
    }

    c->cd(0);
    TLatex* ltx = new TLatex(0.5, 0.987,
        Form("Example events -- Signal ev %d vs Background ev %d", sigEv, bkgEv));
    ltx->SetNDC(); ltx->SetTextAlign(23);
    ltx->SetTextSize(0.022); ltx->SetTextFont(62);
    ltx->Draw();

    c->Update();
    return c;
}

// ---- Save all outputs -------------------------------------------------------

void SaveAll() {
    Printf("\n==> Generating all plots ...");

    TFile* fout = new TFile(kOutRoot, "RECREATE");

    // Open PDF
    // First page: blank title page drawn on a temporary canvas
    {
        TCanvas* cTitle = new TCanvas("cTitle", "", 1280, 900);
        cTitle->cd();
        TLatex tl;
        tl.SetNDC(); tl.SetTextAlign(22); tl.SetTextFont(62);
        tl.SetTextSize(0.06);
        tl.DrawLatex(0.5, 0.62, "AI Trigger System");
        tl.SetTextSize(0.04); tl.SetTextFont(42);
        tl.DrawLatex(0.5, 0.53, "Waveform Visualization");
        tl.SetTextSize(0.030);
        tl.DrawLatex(0.5, 0.44,
            Form("%d events  |  %d signal (%.1f%%)  |  %d background (%.1f%%)",
                 kNEvents,
                 CountLabel(1), 100.0*CountLabel(1)/kNEvents,
                 CountLabel(0), 100.0*CountLabel(0)/kNEvents));
        tl.SetTextSize(0.025); tl.SetTextColor(kGray+1);
        tl.DrawLatex(0.5, 0.36, "4 channels  |  256 time samples  |  12-bit ADC");
        cTitle->Update();
        cTitle->Print(Form("%s(", kOutPDF));  // opens the PDF
        delete cTitle;
    }

    // Page 2: Summary histograms
    {
        TCanvas* c = MakeSummaryCanvas();
        c->Print(kOutPDF);
        c->Write("cSummary");
        // Also write the individual histograms
        for (auto* obj : *c->GetListOfPrimitives()) obj->Write();
        delete c;
    }

    // Page 3: Overlay of all channels
    {
        TCanvas* c = MakeOverlayCanvas(25);
        c->Print(kOutPDF);
        c->Write("cOverlayAll");
        delete c;
    }

    // Pages 4-6: Three pairs of example events (signal vs background)
    int examplePairs[3][2] = {{0,0}, {1,1}, {2,2}}; // Nth signal, Nth background
    for (int i = 0; i < 3; ++i) {
        TCanvas* c = MakeExampleCanvas(examplePairs[i][0], examplePairs[i][1], i);
        if (!c) continue;
        c->Print(kOutPDF);
        c->Write(Form("cExample_%d", i));
        delete c;
    }

    // Close PDF
    {
        TCanvas* cClose = new TCanvas("cClose", "", 1, 1);
        cClose->Print(Form("%s)", kOutPDF));  // closes the PDF
        delete cClose;
    }

    fout->Close();
    delete fout;

    Printf("\n==> Saved: %s", kOutPDF);
    Printf("==> Saved: %s\n", kOutRoot);
}

// ---- Interactive browser ----------------------------------------------------

void StartBrowser(int startEvent = 0) {
    DrawEvent(startEvent);

    TControlBar* bar = new TControlBar("vertical",
                                       "Waveform Browser", 10, 10);
    bar->SetButtonWidth(160);
    bar->AddButton("Prev Event",    "PrevEvent()",       "Previous event");
    bar->AddButton("Next Event",    "NextEvent()",       "Next event");
    bar->AddButton("Prev Signal",   "PrevSignal()",      "Previous signal event");
    bar->AddButton("Next Signal",   "NextSignal()",      "Next signal event");
    bar->AddButton("---",           "",                  "");
    bar->AddButton("Overlay",       "MakeOverlayCanvas(20)", "Overlay sig vs bkg");
    bar->AddButton("Summary",       "MakeSummaryCanvas()",   "Summary histograms");
    bar->AddButton("Save All",      "SaveAll()",         "Save PDF + ROOT");
    bar->AddButton("---",           "",                  "");
    bar->AddButton("Quit",          ".q",                "Exit ROOT");
    bar->Show();
    gROOT->SaveContext();
}

// ---- Entry point ------------------------------------------------------------

void visualize_waveforms(bool interactive = false) {
    gStyle->SetOptStat(0);
    gStyle->SetPadTickX(1);
    gStyle->SetPadTickY(1);
    gStyle->SetHistLineWidth(2);
    gStyle->SetTitleFontSize(0.052);
    gStyle->SetLabelSize(0.042, "XY");
    gStyle->SetTitleSize(0.046, "XY");

    if (!LoadData()) return;

    if (interactive) {
        StartBrowser(0);
    } else {
        // Batch mode: generate and save everything
        gROOT->SetBatch(kTRUE);
        SaveAll();
        gROOT->SetBatch(kFALSE);
    }
}
