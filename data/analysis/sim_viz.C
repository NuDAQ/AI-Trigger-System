// =============================================================================
// sim_viz.C
// CERN ROOT macro to visualize AI Trigger System simulation results.
//
// Reads three log files written by tb_temp_sys_top.sv during simulation:
//   sim_waveforms.txt   -- ADC samples for each injected event
//   sim_triggers.txt    -- L0_PRE_TRIG rising-edge timestamps
//   sim_cnn_results.txt -- CNN output score + timestamp per event
//
// Usage (run from data/analysis/):
//   root -l -b -q sim_viz.C          // batch: generate sim_results.pdf + .root
//   root -l 'sim_viz.C(true)'        // interactive mode
// =============================================================================

#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <algorithm>

// ---- Data structures --------------------------------------------------------

struct WaveSample {
    int    test_num, event_idx, label;
    long long time_ps;
    int    sample;
    int    ch[4];
};

struct TrigEntry {
    long long time_ps;
    int    test_num, event_idx, label;
};

struct CnnResult {
    int    test_num, event_idx, label;
    long long cnn_score;
    long long time_ps;
};

// ---- File paths -------------------------------------------------------------
static const char* kWaveFile = "sim_waveforms.txt";
static const char* kTrigFile = "sim_triggers.txt";
static const char* kCnnFile  = "sim_cnn_results.txt";
static const char* kOutPDF   = "sim_results.pdf";
static const char* kOutRoot  = "sim_results.root";

static const int kNCh = 4;
static const char* kChName[kNCh]  = {"Ch 0", "Ch 1", "Ch 2", "Ch 3"};
static const int   kChColor[kNCh] = {kBlue+1, kRed+1, kGreen+2, kOrange+1};

// ---- Loader helpers ---------------------------------------------------------

std::vector<WaveSample> LoadWaveforms() {
    std::vector<WaveSample> data;
    std::ifstream f(kWaveFile);
    if (!f.is_open()) { Error("LoadWaveforms","Cannot open %s", kWaveFile); return data; }
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        WaveSample s;
        std::istringstream ss(line);
        ss >> s.test_num >> s.event_idx >> s.label >> s.time_ps >> s.sample
           >> s.ch[0] >> s.ch[1] >> s.ch[2] >> s.ch[3];
        data.push_back(s);
    }
    Printf("==> Loaded %zu waveform samples from %s", data.size(), kWaveFile);
    return data;
}

std::vector<TrigEntry> LoadTriggers() {
    std::vector<TrigEntry> data;
    std::ifstream f(kTrigFile);
    if (!f.is_open()) { Warning("LoadTriggers","Cannot open %s (no triggers?)", kTrigFile); return data; }
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        TrigEntry t;
        std::istringstream ss(line);
        ss >> t.time_ps >> t.test_num >> t.event_idx >> t.label;
        data.push_back(t);
    }
    Printf("==> Loaded %zu trigger entries from %s", data.size(), kTrigFile);
    return data;
}

std::vector<CnnResult> LoadCnnResults() {
    std::vector<CnnResult> data;
    std::ifstream f(kCnnFile);
    if (!f.is_open()) { Warning("LoadCnnResults","Cannot open %s", kCnnFile); return data; }
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        CnnResult r;
        std::istringstream ss(line);
        ss >> r.test_num >> r.event_idx >> r.label >> r.cnn_score >> r.time_ps;
        data.push_back(r);
    }
    Printf("==> Loaded %zu CNN results from %s", data.size(), kCnnFile);
    return data;
}

// ---- Per-event waveform canvas ----------------------------------------------

// Returns canvas for test_num (one pad per channel + trigger markers)
TCanvas* MakeWaveCanvas(int test_num,
                        const std::vector<WaveSample>& waves,
                        const std::vector<TrigEntry>&  trigs,
                        const std::vector<CnnResult>&  cnns)
{
    // Collect samples for this event
    std::vector<WaveSample> ev;
    for (auto& s : waves) if (s.test_num == test_num) ev.push_back(s);
    if (ev.empty()) return nullptr;

    // Sort by sample index
    std::sort(ev.begin(), ev.end(),
              [](const WaveSample& a, const WaveSample& b){ return a.sample < b.sample; });

    int event_idx = ev[0].event_idx;
    int label     = ev[0].label;
    long long t0  = ev[0].time_ps;  // injection start time

    // CNN score for this event
    long long cnn_score = -1;
    for (auto& r : cnns) if (r.test_num == test_num) { cnn_score = r.cnn_score; break; }

    // Trigger times (relative to injection, in sample units)
    // Sample period: FAST_CLK_PERIOD(16) / 16 samples = 1 time unit per sample
    // But we track by sample index directly from waveform data
    // Map: sim time -> sample index by interpolation
    std::vector<double> trig_samples;
    for (auto& t : trigs) {
        if (t.test_num == test_num) {
            // Find the sample closest to this trigger time
            long long dt = t.time_ps - t0;
            // Each batch of 16 samples spans FAST_CLK_PERIOD time units
            // Since $time changes per batch (16 samples per clock), find the closest entry
            double best_sample = 0;
            long long best_dt = 1e18;
            for (auto& s : ev) {
                long long d = std::abs(s.time_ps - t.time_ps);
                if (d < best_dt) { best_dt = d; best_sample = s.sample; }
            }
            trig_samples.push_back(best_sample);
        }
    }

    // Y-range: find min/max across all channels
    double ymin = 4095, ymax = 0;
    for (auto& s : ev)
        for (int c = 0; c < kNCh; ++c) {
            ymin = std::min(ymin, (double)s.ch[c]);
            ymax = std::max(ymax, (double)s.ch[c]);
        }
    double mg = std::max((ymax - ymin) * 0.12, 5.0);

    auto* c = new TCanvas(Form("cWave_%d", test_num),
                          Form("Event Waveform -- Test %d", test_num),
                          100, 100, 1280, 900);
    c->Divide(2, 2, 0.002, 0.002);

    for (int ch = 0; ch < kNCh; ++ch) {
        TVirtualPad* pad = c->cd(ch + 1);
        pad->SetGrid();
        pad->SetLeftMargin(0.12);
        pad->SetBottomMargin(0.13);

        TH1F* hFrame = pad->DrawFrame(0, ymin - mg, (int)ev.size() - 1, ymax + mg);
        hFrame->SetTitle(Form(
            "%s  |  Event #%d  |  Label: %s  |  CNN Score: %lld"
            ";Sample Index;ADC Count (12-bit)",
            kChName[ch], event_idx,
            label == 1 ? "#color[2]{SIGNAL}" : "#color[4]{Background}",
            cnn_score));
        hFrame->GetXaxis()->SetTitleOffset(1.1);
        hFrame->GetYaxis()->SetTitleOffset(1.4);

        // Waveform graph
        auto* gr = new TGraph((int)ev.size());
        for (int i = 0; i < (int)ev.size(); ++i)
            gr->SetPoint(i, ev[i].sample, ev[i].ch[ch]);
        gr->SetLineColor(kChColor[ch]);
        gr->SetLineWidth(2);
        gr->Draw("L SAME");

        // Draw baseline reference line
        TLine* lBase = new TLine(0, 2044, (int)ev.size()-1, 2044);
        lBase->SetLineColor(kGray+1);
        lBase->SetLineStyle(2);
        lBase->SetLineWidth(1);
        lBase->Draw();

        // Draw trigger markers
        for (double ts : trig_samples) {
            TLine* ltrig = new TLine(ts, ymin - mg, ts, ymax + mg);
            ltrig->SetLineColor(kMagenta+1);
            ltrig->SetLineStyle(9);
            ltrig->SetLineWidth(2);
            ltrig->Draw();
        }

        // Legend on first pad only
        if (ch == 0 && !trig_samples.empty()) {
            TLegend* leg = new TLegend(0.60, 0.76, 0.95, 0.92);
            TGraph*  gW  = new TGraph(); gW->SetLineColor(kChColor[0]); gW->SetLineWidth(2);
            TLine*   lT  = new TLine();  lT->SetLineColor(kMagenta+1);  lT->SetLineStyle(9); lT->SetLineWidth(2);
            TLine*   lB  = new TLine();  lB->SetLineColor(kGray+1);     lB->SetLineStyle(2);
            leg->AddEntry(gW, "ADC Waveform",   "L");
            leg->AddEntry(lT, "L0_PRE_TRIG",    "L");
            leg->AddEntry(lB, "Noise baseline", "L");
            leg->SetBorderSize(1); leg->SetTextSize(0.038);
            leg->Draw();
        }
    }

    // Main canvas title
    c->cd(0);
    TLatex* ltx = new TLatex(0.5, 0.987,
        Form("Sim Test %d | Dataset Event #%d | Label: %s | CNN Score: %lld",
             test_num, event_idx,
             label == 1 ? "SIGNAL" : "Background",
             cnn_score));
    ltx->SetNDC(); ltx->SetTextAlign(23);
    ltx->SetTextSize(0.020); ltx->SetTextFont(62);
    ltx->Draw();

    c->Update();
    return c;
}

// ---- CNN score summary canvas -----------------------------------------------

TCanvas* MakeCnnSummaryCanvas(const std::vector<CnnResult>& cnns,
                               const std::vector<TrigEntry>&  trigs)
{
    if (cnns.empty()) { Warning("MakeCnnSummaryCanvas","No CNN results."); return nullptr; }

    int nev = (int)cnns.size();

    auto* c = new TCanvas("cCnnSummary", "CNN Score & Trigger Summary",
                          200, 150, 1280, 700);
    c->Divide(2, 1, 0.005, 0.005);

    // ---- Pad 1: CNN score per injected event (bar chart) ----
    {
        c->cd(1);
        gPad->SetGrid();
        gPad->SetLeftMargin(0.15);
        gPad->SetBottomMargin(0.15);

        double scoreMax = 0;
        for (auto& r : cnns) scoreMax = std::max(scoreMax, (double)r.cnn_score);

        auto* hScore = new TH1D("hCnnScore",
                                "CNN Output Score per Injected Event"
                                ";Injection Index;CNN Score (raw 32-bit)",
                                nev, -0.5, nev - 0.5);
        for (auto& r : cnns)
            hScore->SetBinContent(r.test_num + 1, r.cnn_score);

        // Draw bar-by-bar as individual histograms for color support
        hScore->SetMaximum(scoreMax * 1.25);
        hScore->SetBarWidth(0.6); hScore->SetBarOffset(0.2);
        hScore->SetFillColor(kAzure+7);
        hScore->SetLineColor(kBlue+2);
        hScore->Draw("B TEXT0");

        // Overlay per-bar coloring
        for (auto& r : cnns) {
            auto* hBar = new TH1D(Form("hBar_%d", r.test_num), "",
                                  nev, -0.5, nev - 0.5);
            hBar->SetBinContent(r.test_num + 1, r.cnn_score);
            hBar->SetBarWidth(0.6); hBar->SetBarOffset(0.2);
            hBar->SetFillColor(r.label == 1 ? kRed-4 : kAzure+7);
            hBar->SetLineColor(r.label == 1 ? kRed+1  : kBlue+2);
            hBar->Draw("B SAME");
        }

        // Draw a threshold indicator at 65536 (0x10000) as a rough midpoint
        double thresh = 65536.0;
        if (thresh < scoreMax) {
            TLine* lThr = new TLine(-0.5, thresh, nev - 0.5, thresh);
            lThr->SetLineColor(kOrange+1); lThr->SetLineStyle(7); lThr->SetLineWidth(2);
            lThr->Draw();
            TLatex tl;
            tl.SetTextSize(0.028); tl.SetTextColor(kOrange+1); tl.SetTextAlign(12);
            tl.DrawLatex(0.1, thresh * 1.03, "Score = 65536");
        }

        TLegend* leg = new TLegend(0.60, 0.77, 0.92, 0.92);
        TH1D* hS = new TH1D(); hS->SetFillColor(kRed-4);  hS->SetLineColor(kRed+1);
        TH1D* hB = new TH1D(); hB->SetFillColor(kAzure+7); hB->SetLineColor(kBlue+2);
        leg->AddEntry(hS, "Signal (label=1)",     "F");
        leg->AddEntry(hB, "Background (label=0)", "F");
        leg->SetBorderSize(1); leg->SetTextSize(0.038);
        leg->Draw();
    }

    // ---- Pad 2: Trigger & CNN timing overview ----
    {
        c->cd(2);
        gPad->SetGrid();
        gPad->SetLeftMargin(0.15);
        gPad->SetBottomMargin(0.15);

        // Find time range
        long long tmin = 1e18, tmax = 0;
        for (auto& r : cnns) { tmin = std::min(tmin, r.time_ps); tmax = std::max(tmax, r.time_ps); }
        for (auto& t : trigs) { tmin = std::min(tmin, t.time_ps); tmax = std::max(tmax, t.time_ps); }
        double span = tmax - tmin;
        double tlo = tmin - span * 0.05, thi = tmax + span * 0.05;

        TH1F* hFrame = gPad->DrawFrame(tlo, -0.5, thi, nev - 0.5);
        hFrame->SetTitle("Event Timeline;Simulation Time (ps);Injection Index");
        hFrame->GetXaxis()->SetTitleOffset(1.2);
        hFrame->GetYaxis()->SetTitleOffset(1.6);

        // CNN valid markers
        for (auto& r : cnns) {
            TMarker* m = new TMarker(r.time_ps, r.test_num, 29);  // star
            m->SetMarkerColor(r.label == 1 ? kRed+1 : kBlue+1);
            m->SetMarkerSize(2.5);
            m->Draw();
            TLatex tl;
            tl.SetTextSize(0.025); tl.SetTextAlign(12); tl.SetTextColor(kBlack);
            tl.DrawLatex(r.time_ps + span * 0.01, r.test_num + 0.08,
                         Form("Score: %lld", r.cnn_score));
        }

        // Trigger markers
        for (auto& t : trigs) {
            TMarker* m = new TMarker(t.time_ps, t.test_num, 23);  // down triangle
            m->SetMarkerColor(kMagenta+1);
            m->SetMarkerSize(1.8);
            m->Draw();
        }

        TLegend* leg = new TLegend(0.16, 0.78, 0.55, 0.92);
        TMarker* mS = new TMarker(); mS->SetMarkerStyle(29); mS->SetMarkerColor(kRed+1);  mS->SetMarkerSize(2.0);
        TMarker* mB = new TMarker(); mB->SetMarkerStyle(29); mB->SetMarkerColor(kBlue+1); mB->SetMarkerSize(2.0);
        TMarker* mT = new TMarker(); mT->SetMarkerStyle(23); mT->SetMarkerColor(kMagenta+1); mT->SetMarkerSize(1.8);
        leg->AddEntry(mS, "CNN valid (signal)",     "P");
        leg->AddEntry(mB, "CNN valid (background)", "P");
        leg->AddEntry(mT, "L0_PRE_TRIG",            "P");
        leg->SetBorderSize(1); leg->SetTextSize(0.032);
        leg->Draw();
    }

    c->Update();
    return c;
}

// ---- Trigger info text canvas -----------------------------------------------

// page: 0-based page index; rowsPerPage: rows per page
TCanvas* MakeSummaryTable(const std::vector<CnnResult>&  cnns,
                           const std::vector<TrigEntry>&  trigs,
                           int page = 0, int rowsPerPage = 10)
{
    int startRow = page * rowsPerPage;
    int endRow   = std::min(startRow + rowsPerPage, (int)cnns.size());
    if (startRow >= (int)cnns.size()) return nullptr;
    int nPages = ((int)cnns.size() + rowsPerPage - 1) / rowsPerPage;

    auto* c = new TCanvas(Form("cTable_%d", page), "Simulation Results Summary",
                          300, 200, 900, 500);
    c->cd();

    TLatex tl;
    tl.SetNDC(); tl.SetTextFont(42);

    // Title (with page indicator when multi-page)
    tl.SetTextSize(0.055); tl.SetTextFont(62); tl.SetTextAlign(22);
    TString title = "Simulation Results Summary";
    if (nPages > 1) title += Form("  (Page %d / %d)", page + 1, nPages);
    tl.DrawLatex(0.5, 0.93, title.Data());

    // Header
    double dy = 0.072;
    double y  = 0.84;
    tl.SetTextSize(0.035); tl.SetTextFont(62); tl.SetTextAlign(12);
    tl.DrawLatex(0.05, y, "Test");
    tl.DrawLatex(0.15, y, "EvIdx");
    tl.DrawLatex(0.28, y, "Label");
    tl.DrawLatex(0.42, y, "CNN Score");
    tl.DrawLatex(0.62, y, "#Triggers");
    tl.DrawLatex(0.80, y, "Result");

    // Divider line
    TLine* ldiv = new TLine(0.04, y - 0.025, 0.96, y - 0.025);
    ldiv->SetLineWidth(2); ldiv->Draw();

    tl.SetTextFont(42); tl.SetTextSize(0.033);
    for (int i = startRow; i < endRow; i++) {
        const auto& r = cnns[i];
        y -= dy;
        // Count triggers for this test
        int ntrig = 0;
        for (auto& t : trigs) if (t.test_num == r.test_num) ++ntrig;

        // "Correct" = L0_PRE_TRIG fired for a genuine signal event (true positive).
        // Background events that trigger are false alarms → Wrong.
        bool correct = (r.label == 1);

        tl.SetTextColor(kBlack);
        tl.DrawLatex(0.05, y, Form("%d", r.test_num));
        tl.DrawLatex(0.15, y, Form("#%d", r.event_idx));

        tl.SetTextColor(r.label == 1 ? kRed+1 : kBlue+1);
        tl.DrawLatex(0.28, y, r.label == 1 ? "SIGNAL" : "Background");

        tl.SetTextColor(kBlack);
        tl.DrawLatex(0.42, y, Form("%lld (0x%llX)", r.cnn_score, r.cnn_score));

        tl.SetTextColor(ntrig > 0 ? kGreen+2 : kGray+1);
        tl.DrawLatex(0.62, y, Form("%d", ntrig));

        tl.SetTextColor(correct ? kGreen+2 : kRed+1);
        tl.DrawLatex(0.80, y, correct ? "Correct" : "Wrong");
    }
    c->Update();
    return c;
}

// ---- Entry point ------------------------------------------------------------

void sim_viz(bool interactive = false)
{
    gStyle->SetOptStat(0);
    gStyle->SetPadTickX(1);
    gStyle->SetPadTickY(1);
    gStyle->SetTitleFontSize(0.050);
    gStyle->SetLabelSize(0.040, "XY");
    gStyle->SetTitleSize(0.044, "XY");

    auto waves = LoadWaveforms();
    auto trigs = LoadTriggers();
    auto cnns  = LoadCnnResults();

    if (waves.empty() && cnns.empty()) {
        Error("sim_viz", "No data loaded. Run the simulation first to generate log files.");
        return;
    }

    // Find how many distinct test events exist
    std::set<int> test_nums;
    for (auto& s : waves) test_nums.insert(s.test_num);
    for (auto& r : cnns)  test_nums.insert(r.test_num);
    Printf("==> Found %zu injected events to visualize.", test_nums.size());

    if (!interactive) gROOT->SetBatch(kTRUE);

    TFile* fout = new TFile(kOutRoot, "RECREATE");

    // Open PDF
    {
        TCanvas* cTitle = new TCanvas("cTitle", "", 1280, 400);
        cTitle->cd();
        TLatex tl; tl.SetNDC(); tl.SetTextAlign(22);
        tl.SetTextSize(0.10); tl.SetTextFont(62);
        tl.DrawLatex(0.5, 0.65, "AI Trigger System -- Simulation Results");
        tl.SetTextSize(0.055); tl.SetTextFont(42);
        tl.DrawLatex(0.5, 0.48, Form("%zu injected events  |  %zu triggers  |  %zu CNN outputs",
                                     test_nums.size(), trigs.size(), cnns.size()));
        tl.SetTextSize(0.038); tl.SetTextColor(kGray+1);
        tl.DrawLatex(0.5, 0.34, "62.5 MHz fast clock  |  200 MHz CNN clock  |  12-bit ADC");
        cTitle->Print(Form("%s(", kOutPDF));
        delete cTitle;
    }

    // Per-event waveform canvases
    if (!waves.empty()) {
        for (int tn : test_nums) {
            TCanvas* c = MakeWaveCanvas(tn, waves, trigs, cnns);
            if (!c) continue;
            c->Print(kOutPDF);
            c->Write(Form("cWave_%d", tn));
            delete c;
        }
    }

    // CNN score + timing summary
    {
        TCanvas* c = MakeCnnSummaryCanvas(cnns, trigs);
        if (c) {
            c->Print(kOutPDF);
            c->Write("cCnnSummary");
            delete c;
        }
    }

    // Text summary table (paginated: 10 rows per page)
    {
        int rowsPerPage = 10;
        int nPages = ((int)cnns.size() + rowsPerPage - 1) / rowsPerPage;
        for (int pg = 0; pg < nPages; pg++) {
            TCanvas* c = MakeSummaryTable(cnns, trigs, pg, rowsPerPage);
            if (c) {
                c->Print(kOutPDF);
                c->Write(Form("cTable_%d", pg));
                delete c;
            }
        }
    }

    // Close PDF
    {
        TCanvas* cClose = new TCanvas("cClose","",1,1);
        cClose->Print(Form("%s)", kOutPDF));
        delete cClose;
    }

    fout->Close();
    delete fout;

    if (!interactive) gROOT->SetBatch(kFALSE);

    Printf("\n==> Saved: %s", kOutPDF);
    Printf("==> Saved: %s\n", kOutRoot);
}
