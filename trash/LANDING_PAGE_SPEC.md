# ANOTE — Landing Page Specification

> Comprehensive, self-contained specification for building the ANOTE product landing page.
> This document is designed to be placed in a **separate repository** and contains everything needed to implement, deploy, and iterate on the marketing website.

---

## Table of Contents

1. [Product Summary](#1-product-summary)
2. [Target Audience](#2-target-audience)
3. [Core Value Propositions](#3-core-value-propositions)
4. [Site Map & Page Structure](#4-site-map--page-structure)
5. [Page-by-Page Block Specification](#5-page-by-page-block-specification)
6. [Visual Design System](#6-visual-design-system)
7. [Animation & Interaction Design](#7-animation--interaction-design)
8. [Media Assets Required](#8-media-assets-required)
9. [Copy & Messaging Guide](#9-copy--messaging-guide)
10. [Forms & Lead Capture](#10-forms--lead-capture)
11. [Technical Implementation](#11-technical-implementation)
12. [Hosting & Deployment (Azure)](#12-hosting--deployment-azure)
13. [SEO & Performance](#13-seo--performance)
14. [Analytics & Tracking](#14-analytics--tracking)
15. [Phase 2: Live Browser Demo](#15-phase-2-live-browser-demo)
16. [Content Translations](#16-content-translations)
17. [Legal & Compliance](#17-legal--compliance)

---

## 1. Product Summary

**ANOTE** is a medical dictation application that transforms doctor-patient conversations into structured medical reports in seconds. It combines privacy-first on-device speech recognition (Whisper + Silero VAD) with AI-powered report generation (Azure OpenAI) to eliminate hours of manual documentation.

### What It Does

1. **Records** — Doctor taps record on their phone during a patient visit
2. **Transcribes** — Speech is converted to text *on the device itself* — no audio ever leaves the phone
3. **Generates** — AI creates a structured, 13-section Czech medical report from the transcript in real-time
4. **Delivers** — Report appears live on screen, can be copied, emailed, or edited

### Key Facts

| | |
|---|---|
| **Platforms** | iOS, Android (Flutter) |
| **Languages** | Czech medical terminology (expandable) |
| **Transcription** | On-device (Whisper Small/Turbo INT8) or Cloud (Azure Whisper API) |
| **Report AI** | Azure OpenAI GPT-4.1-mini (EU West Europe) |
| **Latency** | Live transcript updates every 5–10s, report preview every 15s |
| **Cost per report** | ~$0.001 USD |
| **Data residency** | EU only (Azure West Europe) |
| **Audio storage** | None — audio stays on device, never uploaded |
| **Works offline** | Yes — transcription works without internet (on-device mode) |

### Report Structure (13 sections)

Every generated report follows Czech medical documentation standards:

| Section | Description |
|---------|-------------|
| **Identifikace pacienta** | Name, age/DOB, visit date |
| **NO** (Nynější onemocnění) | Chief complaint, duration, triggers |
| **RA** (Rodinná anamnéza) | Family medical history |
| **OA** (Osobní anamnéza) | Past medical history, surgeries |
| **FA** (Farmakologická anamnéza) | Current medications, dosages |
| **AA** (Alergologická anamnéza) | Drug/food allergies |
| **GA** (Gynekologická/Urologická anamnéza) | Reproductive health |
| **SA** (Sociální anamnéza) | Smoking, alcohol, occupation |
| **Adherence** | Patient's collaboration and compliance |
| **Objektivní nález** | Vitals, physical examination findings |
| **Hodnocení** | Working diagnosis, clinical conclusion |
| **Návrh vyšetření** | Recommended tests, imaging |
| **Návrh terapie & pokyny** | Treatment plan, follow-up |

### Supported Visit Types

- **Ambulantní vyšetření** (initial) — full 13-section comprehensive report
- **Kontrolní vyšetření** (follow-up) — compact progress-focused report
- **Gastroskopie** — endoscopy-specific report
- **Kolonoskopie** — colonoscopy-specific report
- **Ultrazvuk** — organ-by-organ abdominal imaging report
- **Automatický režim** — AI detects visit type from transcript

---

## 2. Target Audience

### Primary: Czech Healthcare Professionals

| Persona | Profile | Pain Point | ANOTE Value |
|---------|---------|------------|-------------|
| **Ambulantní lékař** (Outpatient doctor) | General practitioner, 30–60 patients/day, spends 15–30 min per report manually | Drowning in paperwork after clinic hours, overtime documentation | Record conversation → report in seconds, not hours |
| **Specialista** (Specialist) | Gastroenterologist, cardiologist, internist — needs procedure-specific reports | Every visit type has different documentation requirements | 6 visit types, each with tailored report structure |
| **Vedoucí kliniky** (Clinic manager) | Runs multi-doctor practice, responsible for GDPR compliance and efficiency | Worried about patient data in cloud tools, inconsistent documentation quality | GDPR-compliant architecture, standardised output |

### Secondary

- **Hospital IT departments** evaluating documentation tools
- **Medical software integrators** looking for dictation/report APIs
- **Health-tech investors** tracking EU medtech innovation

### Geographic Focus

Czech Republic first → Slovakia → DACH region (German medical terminology future expansion).

---

## 3. Core Value Propositions

These are the **6 pillars** that every page block should reinforce:

### Pillar 1: Privacy First 🔒
> "Hlas pacienta nikdy neopustí telefon."
> (Patient's voice never leaves the phone.)

- On-device transcription (Whisper runs locally)
- No audio uploaded, ever
- EU-only data processing (Azure West Europe)
- Zero data retention policy on Azure OpenAI
- No model training on patient data

### Pillar 2: Instant Reports ⚡
> "Od nahrávky ke strukturované zprávě za 15 sekund."
> (From recording to structured report in 15 seconds.)

- Live transcript updates every 5–10 seconds
- Report preview refreshes every 15 seconds while still recording
- Final polished report within seconds of stopping
- Edit, copy, email — immediately

### Pillar 3: Medical-Grade Structure 📋
> "13 sekcí. Česká terminologie. Žádné chybějící pole."
> (13 sections. Czech terminology. No missing fields.)

- Reports follow Czech medical documentation standards
- Proper medical terminology automatically applied
- Negation handling (explicit "neguje" vs "neuvedeno")
- ASR error resilience — AI interprets meaning, not typos
- 6 visit types with tailored structures

### Pillar 4: Works Everywhere 📱
> "V ordinaci, v terénu, i bez internetu."
> (In clinic, in the field, even without internet.)

- On-device mode: fully offline transcription
- Cloud mode: highest accuracy when connected
- iOS + Android from same codebase
- Copy → paste into any EHR/EMR system

### Pillar 5: Almost Free 💰
> "~0,03 Kč za zprávu. Bez předplatného."
> (~0.03 CZK per report. No subscription.)

- Pay-as-you-go, no monthly fees
- On-device transcription is completely free
- Only report generation uses cloud resources (~$0.001/report)
- Self-hostable backend for enterprise control

### Pillar 6: GDPR Compliant ✅
> "Navrženo pro evropské zdravotnictví od prvního řádku kódu."
> (Designed for European healthcare from the first line of code.)

- Azure OpenAI West Europe (Standard SKU)
- No patient data leaves the EU
- Abuse monitoring opt-out enabled
- Bearer token authentication on all API calls
- Encryption at rest and in transit

---

## 4. Site Map & Page Structure

```
anote.cz (or anote-medical.com)
│
├── / ............................ Landing Page (single-page with sections)
│   ├── #hero ................... Hero with headline + CTA
│   ├── #how-it-works ........... 3-step pipeline visual
│   ├── #features ............... Feature grid with animations
│   ├── #demo-video ............. Product walkthrough video
│   ├── #report-showcase ........ Interactive report example
│   ├── #visit-types ............ Visit type cards
│   ├── #privacy ................ Privacy & GDPR section
│   ├── #pricing ................ Pricing / cost comparison
│   ├── #testimonials ........... Social proof (quotes, logos)
│   ├── #faq .................... Frequently asked questions
│   └── #cta-bottom ............. Final CTA + contact form
│
├── /demo ....................... [Phase 2] Live browser demo
│
├── /kontakt .................... Contact page / form
│
├── /podminky ................... Terms of service
│
├── /ochrana-soukromi ........... Privacy policy
│
└── /impressum .................. Legal imprint
```

The main landing page is a **single-page scroll experience** with distinct sections. Navigation links scroll to anchor sections. Separate pages only for legal content, contact, and (Phase 2) live demo.

---

## 5. Page-by-Page Block Specification

### 5.1 Navigation Bar (sticky)

**Behaviour:** Transparent on top, becomes solid white/dark with blur-glass effect on scroll (backdrop-filter). Slight shadow on scroll.

| Element | Content |
|---------|---------|
| **Logo** | ANOTE wordmark (left) — bold rounded font, accent color on the "O" or a small medical cross icon |
| **Nav links** | Jak to funguje · Funkce · Cena · Kontakt |
| **Language toggle** | CZ / EN — small pill toggle |
| **CTA button** | "Vyzkoušet demo" (Request Demo) — primary accent color, rounded pill shape |

**Responsive:** On mobile, collapse to hamburger menu with slide-in drawer.

---

### 5.2 Hero Section (#hero)

**Layout concept:** Full viewport height. Left side: text + CTAs. Right side: floating phone mockup showing the app in action, slightly overlapping the section below — creating the "covered/overlapping" feeling. Subtle animated gradient background (slow-moving mesh gradient or soft noise texture).

**Heading (H1):**
```
Lékařské zprávy
z hlasu za sekundy.
```
_(Medical reports from voice in seconds.)_

**Subheading (H2, lighter weight):**
```
Nahrávejte. ANOTE přepíše a vytvoří strukturovanou
lékařskou zprávu — přímo na vašem telefonu.
```
_(Record. ANOTE transcribes and generates a structured
medical report — right on your phone.)_

**CTAs:**
| Button | Style | Action |
|--------|-------|--------|
| "Vyzkoušet zdarma" (Try for free) | Primary — large pill, accent colour, subtle hover scale + glow | Scrolls to #cta-bottom demo request form |
| "Podívejte se, jak to funguje" (See how it works) | Secondary — ghost/outline button with play icon | Scrolls to #demo-video or opens video lightbox |

**Visual element:** iPhone/Android mockup (3D perspective, slightly rotated) showing ANOTE app with a live transcript and report visible. The phone mockup's bottom edge visually **overlaps into the next section** by ~80px, breaking the rigid horizontal line. Soft shadow beneath.

**Background:** Subtle animated mesh gradient (cream/warm white → soft blue/teal tones). Gentle floating particles or soft bokeh dots that move with scroll parallax.

**Trust badges row** (small, below CTAs):
- 🔒 GDPR · 🇪🇺 Data v EU · 📱 iOS & Android · ⚡ Funguje i offline

---

### 5.3 Logo Bar / Social Proof Strip

**Layout:** Horizontal strip between hero and "how it works." Slightly offset upward so it overlaps the hero's bottom edge.

**Content:**
```
Používají lékaři v České republice
```
_(Used by doctors in the Czech Republic)_

Below: Row of grayscale clinic/hospital/partner logos (or placeholder logos with "Vaše klinika?" (Your clinic?) CTA if no real logos yet).

**Animation:** Logos fade in and slightly slide up on scroll-into-view. On hover, individual logos go full-color.

---

### 5.4 How It Works (#how-it-works)

**Layout:** 3 large numbered steps, horizontal on desktop (each taking 1/3 width), stacked vertically on mobile. Each step is a rounded card with a large icon/illustration on top.

**Section heading:**
```
Jak to funguje
```
_(How it works)_

**Subheading:**
```
Tři kroky od nahrávky ke zprávě
```
_(Three steps from recording to report)_

**Steps:**

| # | Icon/Illustration | Title | Description |
|---|-------------------|-------|-------------|
| 01 | Microphone icon with sound waves | **Nahrávejte** (Record) | Zapněte nahrávání během vyšetření. ANOTE zachytí konverzaci přímo na vašem telefonu. _(Start recording during the examination. ANOTE captures the conversation right on your phone.)_ |
| 02 | Waveform → text transformation visual | **Přepisujte** (Transcribe) | Whisper AI přepisuje řeč na text přímo na zařízení — žádný zvuk neopouští telefon. Přepis se aktualizuje živě. _(Whisper AI transcribes speech to text directly on the device — no audio leaves the phone. Transcript updates live.)_ |
| 03 | Document with check mark + report template | **Generujte zprávu** (Generate report) | AI vytvoří strukturovanou lékařskou zprávu s 13 sekcemi dle českých standardů. Hotovo za sekundy. _(AI creates a structured medical report with 13 sections per Czech standards. Done in seconds.)_ |

**Animation:**
- Steps appear sequentially (stagger 200ms) on scroll into view
- A connecting dotted line/arrow flows between the steps
- Each icon has a subtle looping animation (mic pulsing, waveform moving, checkmark drawing)
- Numbers are oversized (72–96px), semi-transparent as background watermark

---

### 5.5 Feature Highlight Blocks (#features)

**Layout concept:** Alternating left-right layout. Each feature is a wide block with text on one side and a visual/screenshot/animation on the other. The visuals **overlap and bleed into adjacent blocks** — e.g., a phone mockup from one block extends 60px into the next block's area, creating that layered, magazine-like feel.

**Section heading:**
```
Funkce, které změní vaši praxi
```
_(Features that will change your practice)_

#### Feature 1: Live Transcription

| | |
|---|---|
| **Title** | Živý přepis v reálném čase |
| **English** | Live real-time transcription |
| **Body** | Přepis se zobrazuje přímo před vámi během vyšetření. Každých 5–10 sekund se text aktualizuje. Vidíte, co AI slyší — ještě než pacient odejde z ordinace. _(Transcript appears right in front of you during the exam. Text updates every 5–10 seconds. You see what the AI hears — before the patient even leaves.)_ |
| **Visual** | Animated mockup: transcript panel with text appearing word by word, typing-cursor effect. Phone screen recording or Lottie animation. |
| **Badge** | ⚡ Aktualizace každých 5 s |

#### Feature 2: Structured Medical Report

| | |
|---|---|
| **Title** | 13 sekcí. Česká terminologie. Automaticky. |
| **English** | 13 sections. Czech terminology. Automatic. |
| **Body** | ANOTE negeneruje jen přepis — vytvoří kompletní lékařskou zprávu s anamnézou, nálezem, diagnózou a terapií. Formát odpovídá českým standardům dokumentace. _(ANOTE doesn't just generate a transcript — it creates a complete medical report with history, findings, diagnosis, and therapy. The format matches Czech documentation standards.)_ |
| **Visual** | Stylised report document with highlighted section headers (NO, RA, OA, FA, AA, GA, SA…). Expandable accordion showing real report content from a demo scenario. |
| **Badge** | 📋 6 typů vyšetření (ambulance, kontrola, gastroskopie, kolonoskopie, ultrazvuk) |

#### Feature 3: Privacy & On-Device

| | |
|---|---|
| **Title** | Hlas pacienta nikdy neopustí telefon |
| **English** | Patient's voice never leaves the phone |
| **Body** | Whisper AI běží přímo na vašem zařízení. Žádný zvuk se neodesílá na server. Na server odchází pouze anonymizovaný text pro vygenerování zprávy — a to výhradně v rámci EU. _(Whisper AI runs directly on your device. No audio is sent to any server. Only anonymised text goes to the server for report generation — exclusively within the EU.)_ |
| **Visual** | Animated diagram: phone icon with a lock, dotted line showing "text only" going to an EU server icon, big ❌ over an audio waveform path. Shield/lock motif. |
| **Badge** | 🔒 GDPR · 🇪🇺 Azure West Europe |

#### Feature 4: Works Offline

| | |
|---|---|
| **Title** | Funguje i bez internetu |
| **English** | Works even without internet |
| **Body** | Přepis řeči na text probíhá lokálně. V terénu, v ambulanci bez WiFi, v nemocnici se slabým signálem — ANOTE přepisuje vždy. Pro generování zprávy stačí mobilní data. _(Speech-to-text runs locally. In the field, in a clinic without WiFi, in a hospital with weak signal — ANOTE transcribes always. Mobile data is enough for report generation.)_ |
| **Visual** | Split visual: left side = phone with WiFi-off icon and transcription running, right side = airplane-mode icon with green checkmark |
| **Badge** | 📡 3 režimy: offline / cloud / hybridní |

#### Feature 5: Multiple Visit Types

| | |
|---|---|
| **Title** | Správná šablona pro každé vyšetření |
| **English** | The right template for every examination |
| **Body** | Ambulantní vyšetření, kontrola, gastroskopie, kolonoskopie, ultrazvuk — každý typ vyšetření má vlastní strukturu zprávy. Nebo nechte AI typ rozpoznat automaticky. _(Initial visit, follow-up, gastroscopy, colonoscopy, ultrasound — each visit type has its own report structure. Or let the AI detect the type automatically.)_ |
| **Visual** | Horizontal scroll carousel of 6 report type cards, each with a distinct icon and mini-preview of section headers |
| **Badge** | 🤖 Automatická detekce typu |

#### Feature 6: One-Tap Workflow

| | |
|---|---|
| **Title** | Jedno klepnutí. Žádné přepisování. |
| **English** | One tap. No retyping. |
| **Body** | Klepněte na nahrát, mluvte s pacientem, klepněte na stop. Zprávu zkopírujte do schránky nebo odešlete emailem — přímo do vašeho EHR systému. _(Tap record, speak with the patient, tap stop. Copy the report to clipboard or send via email — straight into your EHR system.)_ |
| **Visual** | 3-icon flow: Record button → stop button → clipboard/email icon, with animated connecting arrows |
| **Badge** | 📧 Email odesílání · 📋 Kopírovat do schránky |

---

### 5.6 Product Video / Demo Walkthrough (#demo-video)

**Layout:** Full-width block with a dark/gradient background that contrasts with the rest of the page. Rounded-corner embedded video player (16:9) centered, with a large custom play button overlay.

**Section heading:**
```
Podívejte se, jak ANOTE funguje
```
_(See how ANOTE works)_

**Subheading:**
```
2 minuty, které ušetří hodiny práce
```
_(2 minutes that will save hours of work)_

**Video content (to produce):**
1. Screen recording of the mobile app being used (15s) — doctor taps record
2. Live transcript appearing during a sample conversation (20s)
3. Report generating in real-time (15s)
4. Copying report to clipboard / emailing (10s)
5. Settings screen showing visit type selection (10s)
6. Closing shot with logo + CTA

**Fallback (if no video yet):** Series of 4–5 high-quality app screenshots in a horizontal carousel, each with a caption describing the step.

**CTA below video:**
```
"Chci vyzkoušet ANOTE" → scrolls to demo request form
```

**Animation:** Video card has a parallax float effect — slightly lifts/tilts on scroll. Play button pulses gently.

---

### 5.7 Interactive Report Showcase (#report-showcase)

**Layout:** A full-width block with a rendered example of a real ANOTE report. Left side: the raw transcript text (styled like a chat/conversation). Right side: the generated 13-section report with collapsible sections.

**Section heading:**
```
Z konverzace ke zprávě
```
_(From conversation to report)_

**Content:**

**Left panel — "Přepis"** (Transcript):
Display a sanitised/demo version of one of the demo scenarios (e.g., respiratory infection):
```
Lékař: Dobrý den, co vás trápí?
Pacient: Dobrý den, pane doktore. Asi pět dní kašlu,
         je to čím dál horší. Mám i dušnost...
[continues for ~15 lines]
```

**Right panel — "Zpráva"** (Report):
Generated report with collapsible accordion sections:
- Each section header (NO, RA, OA, etc.) is clickable
- Opens to show the generated content
- Visual highlighting showing how transcript phrases map to report sections (optional: connecting lines on hover)

**Animation:**
- On scroll into view, the transcript appears first (typewriter effect), then an animated arrow, then the report sections fade in one by one
- Clicking a section header smoothly expands it
- A floating "Vygenerováno za 12 s" (Generated in 12s) badge appears with a timer animation

**CTA:**
```
"Vyzkoušejte s vlastním textem" → scrolls to demo request form
(Phase 2: links to /demo)
```

---

### 5.8 Visit Type Cards (#visit-types)

**Layout:** Horizontal row of 6 cards (scroll on mobile). Each card is a rounded rectangle with an icon, title, and 3–4 bullet points listing the sections specific to that report type. Cards have a subtle gradient background and elevate on hover.

| Card | Icon | Title | Key Sections |
|------|------|-------|-------------|
| 1 | 🏥 | Ambulantní vyšetření | NO, RA, OA, FA, AA, GA, SA, Nález, Diagnóza, Terapie |
| 2 | 🔄 | Kontrolní vyšetření | Subjektivně, Změny, Compliance, Hodnocení, Plán |
| 3 | 🔬 | Gastroskopie | Indikace, Premedikace, Přístroj, Nález, Závěr |
| 4 | 🔬 | Kolonoskopie | Dosah, Polypy, Divertikly, Biopsie, Kontroly |
| 5 | 📡 | Ultrazvuk | Játra, Žlučník, Pankreas, Ledviny, Slezina |
| 6 | 🤖 | Automatický režim | AI rozpozná typ z přepisu a zvolí správnou šablonu |

**Animation:** Cards slide in from below with stagger. On hover: card lifts (translateY -8px) + shadow deepens + subtle border-color shift to accent.

---

### 5.9 Privacy & Security Section (#privacy)

**Layout:** Dark background block (deep navy/charcoal) for visual contrast. Large shield icon or lock illustration as centerpiece. Stats/facts arranged around it in a radial or grid layout.

**Section heading (white text):**
```
Bezpečnost na prvním místě
```
_(Security first)_

**Subheading:**
```
Navrženo pro evropské zdravotnictví
```
_(Designed for European healthcare)_

**Feature grid (2×3 or 3×2):**

| Icon | Title | Detail |
|------|-------|--------|
| 🔒 | Šifrování | End-to-end šifrování při přenosu i v klidu |
| 📱 | On-device AI | Přepis probíhá lokálně, žádný zvuk neopouští zařízení |
| 🇪🇺 | EU data residency | Azure West Europe — data zůstávají v EU |
| 🚫 | Zero retention | Žádné uchovávání dat na serverech Azure OpenAI |
| 🔑 | Token auth | Každý API požadavek autentizován bearer tokenem |
| 🏢 | Self-host option | Backend lze nasadit na vlastní infrastrukturu |

**Animation:** Grid items fade in with stagger. Shield icon has a subtle pulse/glow animation.

**CTA:**
```
"Stáhnout bezpečnostní whitepaper" (download link or email gate)
```

---

### 5.10 Pricing / Cost Comparison (#pricing)

**Layout:** Clean, centered block. One main pricing card (since it's pay-as-you-go, not tiered SaaS — yet). Comparison table below.

**Section heading:**
```
Transparentní ceník
```
_(Transparent pricing)_

**Subheading:**
```
Žádné předplatné. Platíte jen za to, co používáte.
```
_(No subscription. You pay only for what you use.)_

**Main pricing card:**

```
┌─────────────────────────────────────────────┐
│  ANOTE Pro                                   │
│                                              │
│  ~0,03 Kč / zpráva                          │
│  (~$0.001 USD)                               │
│                                              │
│  ✓ Neomezené nahrávání                       │
│  ✓ On-device přepis zdarma                   │
│  ✓ 13-sekční strukturované zprávy            │
│  ✓ 6 typů vyšetření                          │
│  ✓ iOS + Android                             │
│  ✓ GDPR compliant                            │
│  ✓ Email odesílání                           │
│  ✓ Historie nahrávek                         │
│                                              │
│  [ Vyzkoušet zdarma ]                        │
└─────────────────────────────────────────────┘
```

**Cost comparison table:**

| | ANOTE | Ruční přepis | Jiná řešení* |
|---|---|---|---|
| **Čas na zprávu** | ~15 sekund | 15–30 minut | 2–5 minut |
| **Náklad na zprávu** | ~0,03 Kč | Čas lékaře (~150 Kč při 600 Kč/hod) | 10–50 Kč |
| **Data v EU** | ✅ | N/A | ❌ Často US |
| **Audio na serveru** | ❌ Nikdy | N/A | ✅ Často ano |
| **Funguje offline** | ✅ | ✅ | ❌ Většinou ne |
| **Česká terminologie** | ✅ | Závisí na lékaři | ❌ Obecná |

_* Orientační srovnání s komerčními diktovacími službami_

**Animation:** Pricing card scales up slightly on scroll-in. Comparison rows highlight on hover.

**CTA:**
```
"Začít zdarma" → demo request form
```

---

### 5.11 Testimonials / Social Proof (#testimonials)

**Layout:** Carousel of testimonial cards on a light background. Each card is a rounded rectangle with a large quotation mark icon, the quote, and the person's name/role/clinic.

**Section heading:**
```
Co říkají lékaři
```
_(What doctors say)_

**Placeholder testimonials** (replace with real ones):

> "Konečně nemusím po ordinaci sedět hodinu nad počítačem. ANOTE mi ušetří minimálně 2 hodiny denně."
> — **MUDr. [Jméno]**, praktický lékař, Praha

> "Překvapilo mě, jak přesně AI rozumí české lékařské terminologii. Zprávy skoro nemusím upravovat."
> — **MUDr. [Jméno]**, internista, Brno

> "Klíčové pro nás byla GDPR compliance. Žádný zvuk neopouští telefon — to jsme jinde nenašli."
> — **MUDr. [Jméno]**, vedoucí lékař, [Město]

**If no real testimonials yet:** Replace with "Staňte se jedním z prvních uživatelů" (Become one of the first users) + early access signup CTA.

**Animation:** Cards auto-scroll slowly. Manual swipe/drag. Current card is elevated, adjacent cards are slightly smaller (scale 0.9) and faded.

---

### 5.12 FAQ Section (#faq)

**Layout:** Accordion-style FAQ. Clean, centered column (max-width ~800px). Each question is clickable, expanding to reveal the answer with a smooth height animation.

**Section heading:**
```
Často kladené otázky
```
_(Frequently asked questions)_

**Questions & Answers:**

**Q: Je nahrávka pacienta někam odesílána?**
A: Ne. Přepis řeči na text (Whisper AI) probíhá výhradně na vašem zařízení. Na server se odesílá pouze anonymizovaný text přepisu pro vygenerování zprávy — v rámci EU infrastruktury Azure.

**Q: Jak přesný je přepis v češtině?**
A: Pro lékařskou diktaci (jeden mluvčí, tichá místnost) je přesnost vysoká. Přepis využívá model Whisper optimalizovaný pro češtinu s filtrací ticha (VAD). AI generátor zpráv navíc dokáže interpretovat i drobné chyby přepisu.

**Q: Mohu zprávu upravit před odesláním?**
A: Ano. Vygenerovaná zpráva je plně editovatelná přímo v aplikaci. Můžete ji upravit, zkopírovat do schránky nebo odeslat emailem.

**Q: Jaké typy vyšetření aplikace podporuje?**
A: Ambulantní vyšetření, kontrolní vyšetření, gastroskopii, kolonoskopii a ultrazvuk. Můžete také nechat AI automaticky rozpoznat typ vyšetření z přepisu.

**Q: Funguje aplikace bez internetu?**
A: Přepis řeči funguje plně offline (modely běží na zařízení). Pro vygenerování strukturované zprávy je potřeba připojení k internetu (mobilní data stačí).

**Q: Kolik to stojí?**
A: Přepis je zdarma (on-device). Generování zprávy stojí přibližně 0,03 Kč za zprávu. Žádné měsíční předplatné.

**Q: Na jakých zařízeních ANOTE běží?**
A: iOS (iPhone) a Android. Aplikace je optimalizována pro moderní smartphony s alespoň 2 GB RAM.

**Q: Splňuje ANOTE požadavky GDPR?**
A: Ano. Audio zůstává na zařízení. Textová data jsou zpracovávána výhradně v Azure West Europe. Žádná data se neukládají na serverech a nepoužívají se k trénování modelů.

**Q: Mohu ANOTE napojit na svůj nemocniční systém?**
A: V současné verzi můžete zprávu zkopírovat do schránky nebo odeslat emailem. API integrace s EHR/NIS systémy je v plánu.

**Q: Jak dlouho trvá vygenerování zprávy?**
A: Většinou 5–15 sekund po ukončení nahrávání. Během nahrávání se zobrazuje živý náhled zprávy aktualizovaný každých 15 sekund.

**Animation:** Smooth accordion expand/collapse (CSS max-height or JS). Plus/minus icon rotation on toggle.

---

### 5.13 Bottom CTA & Contact Form (#cta-bottom)

**Layout:** Full-width block with gradient background (primary → accent). Large centered heading, supporting text, and a contact/demo-request form.

**Section heading:**
```
Vyzkoušejte ANOTE ještě dnes
```
_(Try ANOTE today)_

**Subheading:**
```
Zanechte nám kontakt a my vám zařídíme přístup.
```
_(Leave us your contact and we'll arrange access.)_

**Form fields:**

| Field | Type | Required | Placeholder |
|-------|------|----------|------------|
| Jméno | text | ✅ | MUDr. Jan Novák |
| Email | email | ✅ | jan.novak@klinika.cz |
| Telefon | tel | ❌ | +420 ... |
| Typ praxe | select | ❌ | Praktický lékař / Specialista / Klinika / Nemocnice |
| Zpráva | textarea | ❌ | Chci se dozvědět více o... |
| GDPR souhlas | checkbox | ✅ | Souhlasím se zpracováním osobních údajů... |

**Submit button:**
```
"Požádat o demo" — primary accent, large, rounded pill
```

**After submit:** Success message: "Děkujeme! Ozveme se vám do 24 hodin." + confetti micro-animation.

**Alternative CTA (side by side):**
```
📧 info@anote.cz  ·  📞 +420 XXX XXX XXX
```

---

### 5.14 Footer

**Layout:** Dark background (matches nav). 4-column grid on desktop, stacked on mobile.

| Column 1 | Column 2 | Column 3 | Column 4 |
|-----------|----------|----------|----------|
| **ANOTE** logo | **Produkt** | **Podpora** | **Právní** |
| Short tagline | Jak to funguje | Kontakt | Podmínky služby |
| © 2026 | Funkce | FAQ | Ochrana soukromí |
| | Ceník | Email | Impressum |
| | (Phase 2) Demo | | |

**Social links:** LinkedIn · GitHub (if open-sourcing) · Email

**Bottom bar:**
```
© 2026 ANOTE. Navrženo pro české zdravotnictví.
Made with ❤ in Prague
```

---

## 6. Visual Design System

### 6.1 Color Palette

**Primary approach:** Clean medical aesthetic — predominantly white/light with a strong accent colour. Professional but warm, not clinical/cold.

| Role | Color | Hex | Usage |
|------|-------|-----|-------|
| **Primary** | Deep Teal | `#0D9488` | CTAs, links, active states, accent |
| **Primary Dark** | Dark Teal | `#0F766E` | Hover states, headers |
| **Secondary** | Warm Coral | `#F97316` | Secondary CTAs, highlights, badges |
| **Background** | Warm White | `#FAFAF9` | Page background |
| **Surface** | Pure White | `#FFFFFF` | Cards, panels |
| **Text Primary** | Charcoal | `#1C1917` | Headings, body text |
| **Text Secondary** | Warm Gray | `#78716C` | Subtitles, descriptions |
| **Border** | Light Gray | `#E7E5E4` | Card borders, dividers |
| **Dark BG** | Deep Navy | `#0F172A` | Footer, dark sections, contrast blocks |
| **Success** | Green | `#22C55E` | Confirmations, checkmarks |
| **Error** | Red | `#EF4444` | Errors, warnings |

**Gradient combos:**
- Hero background: `#FAFAF9` → `#F0FDFA` (warm white to faint teal)
- CTA blocks: `#0D9488` → `#0891B2` (teal to cyan)
- Dark sections: `#0F172A` → `#1E293B` (deep navy gradient)

### 6.2 Typography

**Primary font:** `Plus Jakarta Sans` or `Nunito` — rounded, modern, highly legible sans-serif with a warm feel. Google Fonts, free.

**Fallback:** `Inter` (if more geometric look desired).

| Level | Font | Size (Desktop) | Size (Mobile) | Weight | Line Height |
|-------|------|----------------|---------------|--------|-------------|
| **H1** (Hero) | Plus Jakarta Sans | 64–80px | 36–44px | 800 (ExtraBold) | 1.1 |
| **H2** (Section) | Plus Jakarta Sans | 44–56px | 28–36px | 700 (Bold) | 1.2 |
| **H3** (Card title) | Plus Jakarta Sans | 28–32px | 22–26px | 700 | 1.3 |
| **H4** (Feature) | Plus Jakarta Sans | 22–24px | 18–20px | 600 (SemiBold) | 1.4 |
| **Body** | Plus Jakarta Sans | 16–18px | 15–16px | 400 (Regular) | 1.6 |
| **Body Small** | Plus Jakarta Sans | 14px | 13px | 400 | 1.5 |
| **Caption** | Plus Jakarta Sans | 12px | 12px | 500 (Medium) | 1.4 |
| **CTA Button** | Plus Jakarta Sans | 16–18px | 15–16px | 600 | 1.0 |

**Key rules:**
- Headings: ALL use big, bold, rounded font. Max 2 lines.
- Body: comfortable reading width (max ~680px per text column)
- Czech diacritics must render perfectly (ě, š, č, ř, ž, ý, á, í, é, ú, ů, ď, ť, ň)

### 6.3 Spacing & Layout

| Token | Value | Usage |
|-------|-------|-------|
| `--space-xs` | 4px | Tiny gaps |
| `--space-sm` | 8px | Compact spacing |
| `--space-md` | 16px | Default spacing |
| `--space-lg` | 24px | Section internal padding |
| `--space-xl` | 48px | Between blocks |
| `--space-2xl` | 80px | Between sections |
| `--space-3xl` | 120px | Major section breaks |

**Max content width:** 1200px centered. Full-bleed backgrounds allowed.

**Border radius:**
- Buttons: `9999px` (full pill shape)
- Cards: `16–24px` (large rounded corners)
- Images: `12–16px`
- Inputs: `12px`

### 6.4 Shadows & Depth

```css
--shadow-sm: 0 1px 2px rgba(0,0,0,0.05);
--shadow-md: 0 4px 6px -1px rgba(0,0,0,0.07), 0 2px 4px -1px rgba(0,0,0,0.04);
--shadow-lg: 0 10px 15px -3px rgba(0,0,0,0.08), 0 4px 6px -2px rgba(0,0,0,0.04);
--shadow-xl: 0 20px 25px -5px rgba(0,0,0,0.08), 0 10px 10px -5px rgba(0,0,0,0.03);
--shadow-glow: 0 0 40px rgba(13, 148, 136, 0.15);  /* teal glow for CTAs */
```

### 6.5 Iconography

- Use **Lucide Icons** (open-source, consistent, rounded style matching the font)
- Icon size: 24px default, 32–48px for feature blocks, 64–80px for hero-level
- Icon color: match text or accent color
- Style: Outline/stroke (not filled), 1.5–2px stroke weight

---

## 7. Animation & Interaction Design

### 7.1 Scroll Animations (Intersection Observer / GSAP / Framer Motion)

| Element | Animation | Trigger | Duration | Easing |
|---------|-----------|---------|----------|--------|
| Section headings | Fade up + slide from below (translateY 30px → 0) | Scroll into view | 600ms | `ease-out-cubic` |
| Feature cards | Staggered fade up (100–200ms delay between siblings) | Scroll into view | 500ms | `ease-out-cubic` |
| Phone mockups | Parallax float (translateY shifts at 0.3× scroll speed) | Continuous scroll | — | Linear |
| Stats/numbers | Count-up animation (0 → final value) | Scroll into view | 1500ms | `ease-out-expo` |
| Trust badges | Fade in + slight scale (0.95 → 1) | Scroll into view | 400ms | `ease-out` |
| Report sections | Sequential accordion reveal | Scroll into view | 300ms each | `ease-in-out` |

### 7.2 Hover Interactions

| Element | Hover Effect |
|---------|-------------|
| **CTA Buttons** | Scale 1.03, shadow → glow, slight brightness increase |
| **Cards** | TranslateY -6px, shadow deepens, border-color shifts to accent |
| **Nav links** | Underline slides in from left (width 0 → 100%), color shift |
| **Logo/partner images** | Grayscale → full color, scale 1.05 |
| **FAQ accordion** | Background highlight, arrow icon rotates |
| **Visit type cards** | Subtle gradient intensifies, icon enlarges slightly |

### 7.3 Click / Tap Interactions

| Element | Click Effect |
|---------|-------------|
| **Buttons** | Quick scale 0.97 → 1.0 (bounce), ripple effect |
| **Accordion items** | Smooth height expand (300ms), plus → minus rotation |
| **Video play button** | Pulse out + fade, video loads |
| **Form submit** | Button shows loading spinner → checkmark → success message |

### 7.4 Page Load Animations

1. Navbar slides down from top (300ms)
2. Hero heading fades up word by word (stagger 50ms)
3. Hero subheading fades in (200ms delay)
4. CTAs fade up (400ms delay)
5. Phone mockup slides in from right (500ms delay, ease-out-back for slight overshoot)
6. Trust badges fade in (600ms delay)

### 7.5 "Overlapping Blocks" Technique

Key design principle: sections should NOT feel like stacked rectangular boxes. Implementation:

- **Phone mockup:** Positioned `margin-bottom: -80px` so it extends into the next section's space. The next section has `padding-top: 100px` to accommodate.
- **Cards:** Some cards in the feature grid have `margin-top: -40px` to overlap the section divider.
- **Section backgrounds:** Use CSS `clip-path` or SVG wave dividers between sections instead of straight lines. Example: `clip-path: polygon(0 0, 100% 0, 100% 85%, 0 100%)`
- **Floating elements:** Decorative blobs or gradient circles that span across section boundaries.
- **Z-index layering:** Feature visuals on z-index 10, section backgrounds on z-index 1, creating natural overlap.

### 7.6 Micro-animations (Lottie / CSS)

| Animation | Usage | Format |
|-----------|-------|--------|
| Microphone pulse | "How it works" step 1 | CSS keyframe or Lottie |
| Waveform → text | "How it works" step 2 | Lottie |
| Report checkmark | "How it works" step 3 | Lottie |
| Shield pulse | Privacy section | CSS keyframe |
| Typing cursor | Transcript demo | CSS keyframe |
| Confetti burst | Form success | Lottie or canvas-confetti |
| Loading spinner | Form submit | CSS keyframe |

---

## 8. Media Assets Required

### 8.1 Screenshots / Mockups

| Asset | Description | Format |
|-------|-------------|--------|
| **Hero phone mockup** | iPhone 15 Pro showing ANOTE home screen with active recording + transcript + report preview. 3D perspective. | PNG (transparent) or 3D render |
| **Transcript screenshot** | Close-up of transcript panel with live text appearing | PNG |
| **Report screenshot** | Close-up of generated report with section headers visible | PNG |
| **Settings screenshot** | Settings screen showing visit type selection | PNG |
| **Recording controls** | Close-up of record/stop buttons during recording (green pulsing indicator) | PNG |
| **History screenshot** | Recording history list with multiple entries | PNG |

### 8.2 Videos

| Video | Duration | Content |
|-------|----------|---------|
| **Product demo** | 90–120s | Full recording → report flow walkthrough (screen recording with voiceover) |
| **Quick teaser** | 15–30s | Compressed hero video (autoplay, muted, looped) for hero background or social |
| **Feature clips** | 10–15s each | Short clips for each feature block (optional, can use screenshots instead) |

### 8.3 Illustrations / Graphics

| Asset | Description |
|-------|-------------|
| **Architecture diagram** | Simplified version of the phone → text → report flow |
| **Privacy shield** | Custom illustration of a shield with medical cross |
| **Section divider waves** | SVG wave/curve shapes for section transitions |
| **Background gradient mesh** | Subtle animated gradient for hero section |
| **Medical icons** | Custom or curated icon set for visit types |

### 8.4 Brand Assets

| Asset | Spec |
|-------|------|
| **ANOTE logo (horizontal)** | Wordmark in Plus Jakarta Sans ExtraBold. "A" could have a subtle medical cross or audio wave integrated. Teal primary color. |
| **ANOTE logo (icon)** | Square icon for favicon, social sharing. Teal background + white "A" or medical cross motif. |
| **Favicon** | 32×32, 16×16, plus apple-touch-icon (180×180) |
| **Open Graph image** | 1200×630 for social sharing |

---

## 9. Copy & Messaging Guide

### 9.1 Voice & Tone

| Attribute | Description |
|-----------|-------------|
| **Professional** | Doctors are the audience — no hype, no buzzwords. Respect their intelligence. |
| **Direct** | Short sentences. Czech is naturally more formal — use "vy" (formal you). |
| **Confident** | State facts, not possibilities. "Zpráva je hotová za 15 sekund" not "Zpráva může být hotová…" |
| **Empathetic** | Acknowledge the real problem: too much paperwork, not enough time for patients. |
| **Czech first** | All primary copy in Czech. English as secondary language toggle. |

### 9.2 Key Messages (Czech + English)

**Tagline:**
- CZ: "Lékařské zprávy z hlasu. Za sekundy."
- EN: "Medical reports from voice. In seconds."

**Value prop one-liner:**
- CZ: "ANOTE přepisuje rozhovor s pacientem a vytvoří strukturovanou lékařskou zprávu — přímo na vašem telefonu, bez odesílání zvuku na server."
- EN: "ANOTE transcribes your patient conversation and generates a structured medical report — right on your phone, without sending audio to any server."

**The problem:**
- CZ: "Průměrný lékař stráví 2–3 hodiny denně psaním dokumentace. To je čas, který by mohl věnovat pacientům."
- EN: "The average doctor spends 2–3 hours daily writing documentation. That's time that could be spent with patients."

**The solution:**
- CZ: "Jeden klepnutí na nahrát. Mluvte s pacientem. Jeden klepnutí na stop. Zpráva je hotová."
- EN: "One tap to record. Talk to your patient. One tap to stop. Report is done."

### 9.3 CTA Copy Variants

| Context | Czech | English |
|---------|-------|---------|
| Primary hero | Vyzkoušet zdarma | Try for free |
| Secondary hero | Podívejte se, jak to funguje | See how it works |
| After features | Chci ANOTE pro svou praxi | I want ANOTE for my practice |
| After pricing | Začít zdarma | Start for free |
| After video | Požádat o demo | Request a demo |
| Bottom CTA | Vyzkoušejte ANOTE ještě dnes | Try ANOTE today |
| Footer | Kontaktujte nás | Contact us |

---

## 10. Forms & Lead Capture

### 10.1 Demo Request Form (Primary)

**Location:** #cta-bottom section, also accessible via sticky nav CTA.

**Fields:**

| Field | Label (CZ) | Type | Validation | Required |
|-------|------------|------|------------|----------|
| name | Jméno a příjmení | text | Min 2 chars | ✅ |
| email | Pracovní email | email | Valid email format | ✅ |
| phone | Telefon | tel | Czech format (+420) | ❌ |
| practice_type | Typ praxe | select: Praktický lékař / Specialista / Klinika / Nemocnice / Jiné | — | ❌ |
| message | Zpráva | textarea | Max 500 chars | ❌ |
| gdpr_consent | Souhlasím se zpracováním osobních údajů za účelem kontaktování. | checkbox | Must be checked | ✅ |

**On submit:**
1. Client-side validation with inline error messages
2. Submit to backend API (e.g., POST /api/contact)
3. Button shows loading spinner
4. Success: green checkmark + "Děkujeme! Ozveme se vám do 24 hodin."
5. Store lead in database / send notification email to team
6. Optional: send confirmation email to the lead

### 10.2 Newsletter / Early Access Signup (Compact)

**Location:** Can appear as a slim inline form within the hero or after features.

**Fields:** Email only + GDPR checkbox.

```
[ váš@email.cz          ] [ Chci přístup → ]
☐ Souhlasím se zpracováním osobních údajů
```

### 10.3 "Request a Demo" Modal (triggered by nav CTA)

Same fields as 10.1, but displayed in a centered modal with backdrop blur. Close on ESC or click-outside.

---

## 11. Technical Implementation

### 11.1 Recommended Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| **Framework** | **Next.js 14+** (App Router) | SSR/SSG for SEO, React ecosystem, excellent performance, Vercel-like DX on Azure |
| **Language** | TypeScript | Type safety, better DX |
| **Styling** | **Tailwind CSS 4** | Utility-first, fast iteration, great for responsive and animation classes |
| **Animations** | **Framer Motion** | Best React animation library for scroll, hover, layout animations |
| **Micro-animations** | **Lottie React** (`lottie-react`) | For complex icon animations (mic pulse, waveform, etc.) |
| **Forms** | **React Hook Form** + **Zod** | Lightweight, performant form handling with schema validation |
| **Icons** | **Lucide React** | Consistent, rounded, open-source icon set |
| **Email** | **Azure Communication Services** or **Resend** | Transactional emails for form confirmations |
| **CMS** (optional) | **Content layer** in Next.js (MDX) or **Sanity** | For blog posts / case studies later |
| **Analytics** | **Plausible** or **Umami** | Privacy-friendly, GDPR-compliant, no cookie banner needed |

### 11.2 Project Structure

```
anote-web/
├── public/
│   ├── images/
│   │   ├── hero-phone-mockup.png
│   │   ├── screenshots/
│   │   ├── icons/
│   │   └── og-image.png
│   ├── videos/
│   │   └── demo.mp4
│   ├── lottie/
│   │   ├── mic-pulse.json
│   │   ├── waveform.json
│   │   └── checkmark.json
│   ├── favicon.ico
│   └── robots.txt
├── src/
│   ├── app/
│   │   ├── layout.tsx           # Root layout, fonts, metadata
│   │   ├── page.tsx             # Landing page (/)
│   │   ├── kontakt/
│   │   │   └── page.tsx         # Contact page
│   │   ├── demo/
│   │   │   └── page.tsx         # [Phase 2] Live demo
│   │   ├── podminky/
│   │   │   └── page.tsx         # Terms of service
│   │   ├── ochrana-soukromi/
│   │   │   └── page.tsx         # Privacy policy
│   │   └── api/
│   │       └── contact/
│   │           └── route.ts     # Contact form API endpoint
│   ├── components/
│   │   ├── layout/
│   │   │   ├── Navbar.tsx
│   │   │   └── Footer.tsx
│   │   ├── sections/
│   │   │   ├── Hero.tsx
│   │   │   ├── LogoBar.tsx
│   │   │   ├── HowItWorks.tsx
│   │   │   ├── Features.tsx
│   │   │   ├── DemoVideo.tsx
│   │   │   ├── ReportShowcase.tsx
│   │   │   ├── VisitTypes.tsx
│   │   │   ├── Privacy.tsx
│   │   │   ├── Pricing.tsx
│   │   │   ├── Testimonials.tsx
│   │   │   ├── FAQ.tsx
│   │   │   └── BottomCTA.tsx
│   │   ├── ui/
│   │   │   ├── Button.tsx
│   │   │   ├── Card.tsx
│   │   │   ├── Input.tsx
│   │   │   ├── Accordion.tsx
│   │   │   ├── Badge.tsx
│   │   │   ├── Modal.tsx
│   │   │   └── SectionDivider.tsx
│   │   └── animations/
│   │       ├── FadeInOnScroll.tsx
│   │       ├── StaggerChildren.tsx
│   │       ├── ParallaxFloat.tsx
│   │       ├── CountUp.tsx
│   │       └── TypewriterText.tsx
│   ├── lib/
│   │   ├── constants.ts         # Colors, config, API URLs
│   │   ├── fonts.ts             # Font loading (Plus Jakarta Sans)
│   │   └── utils.ts             # Helpers
│   ├── hooks/
│   │   ├── useIntersection.ts   # Scroll detection
│   │   └── useForm.ts           # Form helpers
│   └── styles/
│       └── globals.css          # Tailwind imports + CSS custom properties
├── tailwind.config.ts
├── next.config.ts
├── tsconfig.json
├── package.json
├── Dockerfile
└── README.md
```

### 11.3 Key Implementation Notes

**Font loading:**
```tsx
// src/lib/fonts.ts
import { Plus_Jakarta_Sans } from 'next/font/google';

export const jakarta = Plus_Jakarta_Sans({
  subsets: ['latin', 'latin-ext'],  // latin-ext for Czech diacritics
  weight: ['400', '500', '600', '700', '800'],
  display: 'swap',
});
```

**Scroll animation wrapper (Framer Motion):**
```tsx
// src/components/animations/FadeInOnScroll.tsx
'use client';
import { motion } from 'framer-motion';

export function FadeInOnScroll({ children, delay = 0 }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 30 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-100px' }}
      transition={{ duration: 0.6, delay, ease: [0.33, 1, 0.68, 1] }}
    >
      {children}
    </motion.div>
  );
}
```

**Overlapping section technique:**
```tsx
// Hero phone mockup overlapping into next section
<div className="relative z-10 -mb-20">
  <Image src="/images/hero-phone-mockup.png" ... />
</div>

// Next section with extra top padding to accommodate overlap
<section className="relative pt-32 ...">
  ...
</section>
```

**Wave section divider:**
```tsx
// src/components/ui/SectionDivider.tsx
export function SectionDivider({ flip = false }) {
  return (
    <svg viewBox="0 0 1440 80" className={flip ? 'rotate-180' : ''}>
      <path
        d="M0,40 C360,80 720,0 1080,40 C1260,60 1380,50 1440,40 L1440,80 L0,80 Z"
        fill="currentColor"
      />
    </svg>
  );
}
```

---

## 12. Hosting & Deployment (Azure)

### 12.1 Architecture for Minimum Cost + Maximum Speed

```
                                    ┌─────────────────────┐
                                    │  Azure CDN (Front    │
  User ──── HTTPS ────────────────▶│  Door) — caching     │
                                    │  + SSL termination   │
                                    └──────────┬──────────┘
                                               │
                                    ┌──────────▼──────────┐
                                    │  Azure Static Web    │
                                    │  Apps (Free/Standard)│
                                    │  — Next.js SSG/SSR   │
                                    └──────────┬──────────┘
                                               │ (API routes)
                                    ┌──────────▼──────────┐
                                    │  Serverless Function │
                                    │  (built-in to SWA)   │
                                    │  — contact form API   │
                                    └─────────────────────┘
```

### 12.2 Recommended: Azure Static Web Apps

**Why:** Cheapest option for a Next.js site with minimal API routes.

| Tier | Price | Features |
|------|-------|----------|
| **Free** | $0/month | 100 GB bandwidth, 2 custom domains, SSL, global CDN built-in, serverless API routes, GitHub Actions CI/CD |
| **Standard** | ~$9/month | 500 GB bandwidth, 5 custom domains, auth providers, staging environments |

**Region:** West Europe (matches ANOTE backend + GDPR).

**Included for free:**
- Global CDN (Azure Front Door Lite built into SWA)
- Automatic SSL certificates
- CI/CD via GitHub Actions
- Serverless API functions (Node.js)
- Custom domains

### 12.3 Deployment Steps

```bash
# 1. Create Azure Static Web App (one-time, via CLI or Portal)
az staticwebapp create \
  --name anote-web \
  --resource-group anote-rg \
  --location westeurope \
  --sku Free \
  --source https://github.com/YOUR_ORG/anote-web \
  --branch main \
  --app-location "/" \
  --output-location ".next" \
  --login-with-github

# 2. Configure custom domain
az staticwebapp hostname set \
  --name anote-web \
  --resource-group anote-rg \
  --hostname anote.cz

# 3. Environment variables (for API routes)
az staticwebapp appsettings set \
  --name anote-web \
  --resource-group anote-rg \
  --setting-names \
    CONTACT_EMAIL_TO=info@anote.cz \
    SMTP_HOST=smtp.example.com \
    SMTP_USER=... \
    SMTP_PASS=...
```

### 12.4 CI/CD Pipeline (GitHub Actions, auto-generated)

Azure Static Web Apps auto-creates a GitHub Actions workflow:

```yaml
# .github/workflows/azure-static-web-apps.yml (auto-generated)
name: Azure Static Web Apps CI/CD
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build_and_deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Azure/static-web-apps-deploy@v1
        with:
          azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          app_location: "/"
          output_location: ".next"
```

### 12.5 Cost Estimate

| Component | Monthly Cost |
|-----------|-------------|
| Azure Static Web Apps (Free tier) | **$0** |
| Custom domain DNS (if using Azure DNS) | ~$0.50 |
| Bandwidth overage (>100 GB) | $0.20/GB |
| **Total (normal traffic)** | **~$0.50/month** |

If you outgrow Free tier (>100 GB bandwidth or need staging):
| Azure SWA Standard | ~$9/month |

### 12.6 Alternative: Azure Container Apps (if SSR needed)

If pure static/SSG isn't sufficient (e.g., Phase 2 live demo needs server-side processing):

```bash
# Dockerfile for Next.js
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

Deploy:
```bash
az containerapp up \
  --name anote-web \
  --resource-group anote-rg \
  --location westeurope \
  --source . \
  --ingress external \
  --target-port 3000
```

Cost: ~$5–15/month on Consumption tier (scales to zero when idle).

### 12.7 Domain Configuration

| Domain | Points to |
|--------|-----------|
| `anote.cz` | Azure Static Web Apps (CNAME/A record) |
| `www.anote.cz` | Redirect → `anote.cz` |
| `api.anote.cz` | Existing backend (Azure Container Apps) |

---

## 13. SEO & Performance

### 13.1 Performance Targets

| Metric | Target | How |
|--------|--------|-----|
| **Lighthouse Performance** | ≥95 | Next.js SSG, optimised images, font preloading |
| **First Contentful Paint** | <1.2s | Static generation, CDN, font-display: swap |
| **Largest Contentful Paint** | <2.5s | Optimised hero image, preloaded |
| **Cumulative Layout Shift** | <0.05 | Fixed image dimensions, font-display: swap |
| **Total Blocking Time** | <200ms | Minimal JS, tree-shaking, dynamic imports for animations |
| **Bundle size** | <150 KB (first load JS) | Code splitting, dynamic imports for Lottie |

### 13.2 Optimisation Techniques

- **Static Generation (SSG)** for all pages (no server-side rendering needed for marketing site)
- **Image optimisation:** Next.js `<Image>` component with WebP/AVIF, responsive srcset
- **Font optimisation:** `next/font/google` with display: swap, subset: latin-ext
- **Animation lazy-loading:** Framer Motion and Lottie loaded via dynamic imports with `ssr: false`
- **Video:** Lazy-load video player only when section scrolls into view
- **Critical CSS:** Tailwind purges unused styles automatically
- **Preconnect:** `<link rel="preconnect">` for Google Fonts, analytics

### 13.3 SEO Configuration

```tsx
// src/app/layout.tsx
export const metadata = {
  title: 'ANOTE — Lékařské zprávy z hlasu za sekundy',
  description: 'Přepisujte rozhovory s pacienty a generujte strukturované lékařské zprávy pomocí AI. On-device přepis, GDPR compliant, česká terminologie.',
  keywords: ['lékařská dokumentace', 'diktování', 'přepis řeči', 'AI zprávy', 'GDPR', 'česká medicína'],
  openGraph: {
    title: 'ANOTE — Lékařské zprávy z hlasu',
    description: 'AI asistent pro lékařskou dokumentaci. Přepis na zařízení, zprávy za sekundy.',
    images: ['/images/og-image.png'],
    locale: 'cs_CZ',
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'ANOTE — Lékařské zprávy z hlasu',
    description: 'AI asistent pro lékařskou dokumentaci.',
    images: ['/images/og-image.png'],
  },
  alternates: {
    canonical: 'https://anote.cz',
    languages: {
      'cs': 'https://anote.cz',
      'en': 'https://anote.cz/en',
    },
  },
};
```

**Structured data (JSON-LD):**
```json
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "ANOTE",
  "applicationCategory": "HealthApplication",
  "operatingSystem": "iOS, Android",
  "offers": {
    "@type": "Offer",
    "price": "0",
    "priceCurrency": "CZK"
  },
  "description": "AI-powered medical report generation from voice dictation.",
  "availableLanguage": "cs"
}
```

---

## 14. Analytics & Tracking

### 14.1 Recommended: Plausible Analytics (GDPR-friendly)

- **No cookies** → no cookie banner needed
- **EU-hosted** option available
- **Simple dashboard** — pageviews, referrers, goals
- **Cost:** ~$9/month (cloud) or self-hosted free

### 14.2 Events to Track

| Event | Trigger | Purpose |
|-------|---------|---------|
| `page_view` | Every page load | Traffic analysis |
| `cta_click_hero` | Hero CTA button click | Conversion funnel |
| `cta_click_nav` | Nav CTA button click | Top-of-funnel intent |
| `video_play` | Demo video play | Engagement |
| `video_complete` | Demo video finishes | Deep engagement |
| `faq_expand` | FAQ question opened | Interest topics |
| `form_start` | First form field focused | Form engagement |
| `form_submit` | Form successfully submitted | Lead conversion |
| `form_error` | Form validation error | UX issues |
| `visit_type_click` | Visit type card clicked | Feature interest |
| `report_section_expand` | Report showcase section opened | Content engagement |
| `language_toggle` | CZ/EN toggle | Audience segmentation |

### 14.3 UTM Parameters

Support standard UTM tracking for campaigns:
- `?utm_source=linkedin&utm_medium=social&utm_campaign=launch`
- `?utm_source=conference&utm_medium=qr&utm_campaign=medica2026`

---

## 15. Phase 2: Live Browser Demo

> **Not in initial launch.** This section describes the live demo feature to be added later.

### 15.1 Concept

Users can try ANOTE directly in the browser at `/demo` — record their voice, see it transcribed, and get a sample medical report. This replaces the "Request a Demo" flow with a self-serve experience.

### 15.2 Architecture

```
Browser (Web Audio API)
  ↓ PCM 16kHz
WebAssembly Whisper (or cloud API fallback)
  ↓ Transcript text
POST /report (ANOTE backend)
  ↓ Structured report
Render in browser
```

### 15.3 Options

| Approach | Complexity | Quality | Cost |
|----------|------------|---------|------|
| **A: Browser WebAssembly Whisper** | High (compile whisper.cpp to WASM, ~300 MB download) | Good | Free (client-side) |
| **B: Stream audio to backend** | Medium (WebSocket + server-side Whisper or Azure Whisper API) | Best | Cloud transcription costs |
| **C: Azure Speech SDK (JS)** | Low (Microsoft SDK) | Good | Azure Speech pricing |

**Recommended for Phase 2:** Option **C** (Azure Speech SDK for JavaScript) for quickest time to launch, then optionally migrate to WASM for offline browser demo later.

### 15.4 Demo Page UI

```
┌─────────────────────────────────────────────────────┐
│  ANOTE — Vyzkoušejte si to sami                      │
│                                                       │
│  ┌──────────────┐    ┌──────────────────────────┐   │
│  │              │    │  Přepis:                   │   │
│  │   🎙️ REC    │    │  Pacient přišel s bolestí  │   │
│  │  [ STOP ]   │    │  hlavy trvající tři dny... │   │
│  │              │    │                            │   │
│  └──────────────┘    └──────────────────────────┘   │
│                                                       │
│  ┌──────────────────────────────────────────────┐   │
│  │  Zpráva:                                      │   │
│  │  NO: Pacient 58 let, přichází pro bolesti...  │   │
│  │  RA: Neuvedeno.                               │   │
│  │  ...                                           │   │
│  └──────────────────────────────────────────────┘   │
│                                                       │
│  Chcete plnou verzi? [ Stáhnout aplikaci ]           │
└─────────────────────────────────────────────────────┘
```

### 15.5 Demo Constraints

- **Session limit:** Max 60 seconds of recording per demo session
- **Rate limiting:** Max 5 demos per IP per hour
- **Disclaimer:** "Toto je demo. Nepoužívejte pro skutečné pacientské údaje."
- **No data stored:** Audio and transcripts discarded after session
- **Watermark:** "DEMO" watermark on generated reports

### 15.6 Implementation Notes

- Use `navigator.mediaDevices.getUserMedia()` for microphone access
- Stream PCM to Azure Speech SDK or backend WebSocket
- Reuse existing ANOTE `/report` endpoint for report generation
- Add a dedicated `demo` API token with rate limiting
- Track demo usage in analytics (`demo_start`, `demo_complete`, `demo_to_signup`)

---

## 16. Content Translations

### 16.1 Language Strategy

- **Primary:** Czech (CZ) — all content written in Czech first
- **Secondary:** English (EN) — for international visitors, conferences, investors
- **Implementation:** Next.js `next-intl` or `next/international` with `/` (Czech default) and `/en/` prefix

### 16.2 Translation Scope

| Content | CZ | EN |
|---------|----|----|
| Navigation | ✅ | ✅ |
| Hero section | ✅ | ✅ |
| How it works | ✅ | ✅ |
| Features | ✅ | ✅ |
| Pricing | ✅ | ✅ |
| FAQ | ✅ | ✅ |
| Privacy policy | ✅ | ✅ |
| Terms of service | ✅ | ✅ |
| Contact form | ✅ | ✅ |

---

## 17. Legal & Compliance

### 17.1 Required Pages

| Page | URL | Content |
|------|-----|---------|
| **Podmínky služby** | `/podminky` | Terms of service — usage rights, limitations, disclaimers |
| **Ochrana soukromí** | `/ochrana-soukromi` | Privacy policy — what data is collected (form submissions), how it's processed, GDPR rights |
| **Impressum** | `/impressum` | Legal entity, address, IČO, contact person (required by Czech law for commercial websites) |

### 17.2 Cookie Compliance

If using **Plausible** or **Umami** analytics: **no cookie banner needed** (they don't use cookies).

If using Google Analytics or similar: a full cookie consent banner is required (recommend avoiding this).

### 17.3 Form Data Handling

- Form submissions stored securely (encrypted at rest)
- Retention period: 12 months or until lead conversion
- Right to deletion: provide process for GDPR data subject requests
- Consent checkbox required before form submission
- No pre-checked boxes

### 17.4 Medical Disclaimer

Display on the landing page (footer or wherever the demo is shown):

> "ANOTE je nástroj pro podporu lékařské dokumentace. Negeneruje lékařské diagnózy ani doporučení. Veškerý obsah zpráv musí být zkontrolován lékařem před použitím. ANOTE není certifikovaný zdravotnický prostředek."
>
> _(ANOTE is a medical documentation support tool. It does not generate medical diagnoses or recommendations. All report content must be reviewed by a physician before use. ANOTE is not a certified medical device.)_

---

## Appendix A: Complete Sitemap (for reference)

```
https://anote.cz/                     → Landing page (CZ)
https://anote.cz/en/                  → Landing page (EN)
https://anote.cz/kontakt              → Contact page
https://anote.cz/podminky             → Terms of service
https://anote.cz/ochrana-soukromi     → Privacy policy
https://anote.cz/impressum            → Legal imprint
https://anote.cz/demo                 → [Phase 2] Live browser demo
```

## Appendix B: Asset Checklist

- [ ] ANOTE logo (SVG, horizontal + icon variants)
- [ ] Hero phone mockup (PNG, transparent, 3D perspective)
- [ ] App screenshots (6 screens minimum)
- [ ] Product demo video (90–120s)
- [ ] Lottie animations (mic pulse, waveform, checkmark)
- [ ] Section divider SVG waves
- [ ] Open Graph image (1200×630)
- [ ] Favicon set (16, 32, 180, 192, 512)
- [ ] Visit type icons (6)
- [ ] Privacy shield illustration
- [ ] Background gradient mesh texture
- [ ] Partner/clinic logos (or placeholders)

## Appendix C: Environment Variables

```env
# Azure Static Web Apps API (for contact form)
CONTACT_EMAIL_TO=info@anote.cz
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=noreply@anote.cz
SMTP_PASS=...

# Analytics (if using Plausible Cloud)
NEXT_PUBLIC_PLAUSIBLE_DOMAIN=anote.cz

# Phase 2: Demo API
NEXT_PUBLIC_ANOTE_API_URL=https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io
ANOTE_DEMO_API_TOKEN=...

# Phase 2: Azure Speech (browser demo)
NEXT_PUBLIC_AZURE_SPEECH_KEY=...
NEXT_PUBLIC_AZURE_SPEECH_REGION=westeurope
```
