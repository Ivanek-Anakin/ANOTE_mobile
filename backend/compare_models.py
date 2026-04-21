#!/usr/bin/env python3
"""Side-by-side comparison: gpt-4-1-mini (EU) vs gpt-5-mini (US)"""
import requests, time, json, textwrap

EU = "https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io"
US = "https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io"
TOKEN = "_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I"
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

TESTS = [
    {
        "name": "1. Short / simple (cold, headache)",
        "transcript": "Pacient přišel s bolestí hlavy a teplotou 38.5. Kašel a rýma trvají 3 dny. Doporučuji Paralen 500mg.",
        "visit_type": "default",
    },
    {
        "name": "2. Follow-up (post pneumonia)",
        "transcript": "Dobrý den paní doktorko, přicházím na kontrolu. Minulý týden jsem měl zápal plic, byl jsem tady a dostal jsem antibiotika Augmentin. Bral jsem je pravidelně, horečka ustoupila asi po třech dnech. Teď už se cítím mnohem líp, ale pořád trochu kašlu, hlavně ráno. Dýchání je lepší, žádná bolest na hrudi. Spím lépe, jím normálně. Alergie na penicilin nemám, jiné léky neberu žádné. V rodině nikdo nemá plicní problémy. Nekouřím, alkohol příležitostně. Pracuji jako učitel na základní škole.",
        "visit_type": "follow_up",
    },
    {
        "name": "3. Complex initial (angina + otitis, vitals, meds, allergy)",
        "transcript": "Tak pojďte dál, posaďte se. Co vás trápí? Hele doktore, já mám takový problém, bolí mě strašně v krku, nemůžu polykat, a mám horečku asi 39. To trvá od včerejška. A taky mě bolí uši, hlavně to pravé. Rozumím. A berete nějaké léky pravidelně? No, beru Enalapril na tlak, 10 miligramů, a pak Metformin na cukrovku, 500 dvakrát denně. A jste na něco alergický? Jo, na Biseptol, z toho dostanu vyrážku. Dobře. Tak se podíváme. Otevřete pusu... Tak tady vidím zarudlé mandle s bílými čepy. Uši - pravé ucho je zarudlé, bubínek zánětlivé změny. Teplota 39.1. Tlak 145 na 85. Tep 88. Váha 92 kilo. Výška 178. Tak to vypadá na angínu a ještě ten zánět středního ucha. Předepíšu vám antibiotika, Klarithromycin 500 dvakrát denně na 7 dní, a Ibuprofen 400 na bolest a horečku. Kontrola za týden.",
        "visit_type": "initial",
    },
    {
        "name": "4. Pediatric (bronchitis, 4yr girl)",
        "transcript": "Tak maminka přivedla holčičku, je jí 4 roky, má rýmu a kašel asi 5 dní. Horečka do 38 stupňů. Antibiotika zatím nedostávala. Alergie žádné. Poslechově pískoty oboustranně. Nález: oboustranná bronchitida. Předepisuji Mucosolvan sirup třikrát denně a inhalace Ventolinu. Kontrola za 3 dny, pokud se zhorší, přijít dříve.",
        "visit_type": "initial",
    },
    {
        "name": "5. Minimal (stomach pain only)",
        "transcript": "Bolí mě břicho, hlavně nahoře uprostřed, po jídle se to zhoršuje. Trvá to asi týden.",
        "visit_type": "default",
    },
    {
        "name": "6. Cardiology emergency (chest pain, ECG)",
        "transcript": "Pacient muž 62 let přivezen záchrankou s bolestí na hrudi, trvá asi 2 hodiny, svíravá bolest za hrudní kostí s propagací do levé ruky. Pocení, nauzea. Anamnéza: hypertenze, hyperlipidémie, kouří 20 cigaret denně 30 let. Léky: Prestarium 5mg, Atorvastatin 20mg, Anopyrin 100mg. EKG: elevace ST ve svodech II, III, aVF. Troponin pozitivní. Diagnóza: akutní infarkt myokardu spodní stěny. Zahájena duální antiagregace, heparin, překlad na katetrizační sál k urgentní PCI.",
        "visit_type": "initial",
    },
]

def call_report(base_url, transcript, visit_type):
    t0 = time.time()
    try:
        r = requests.post(
            f"{base_url}/report",
            headers=HEADERS,
            json={"transcript": transcript, "visit_type": visit_type},
            timeout=300,
        )
        elapsed = time.time() - t0
        if r.status_code == 200:
            return r.json().get("report", ""), elapsed, r.status_code
        return f"HTTP {r.status_code}: {r.text[:200]}", elapsed, r.status_code
    except Exception as e:
        return f"ERROR: {e}", time.time() - t0, 0

SEP = "=" * 80

for test in TESTS:
    print(f"\n{SEP}")
    print(f"  TEST: {test['name']}")
    print(f"  Visit type: {test['visit_type']}")
    print(f"  Transcript: {test['transcript'][:100]}...")
    print(SEP)

    # Run both in sequence (can't parallelize easily in a script)
    print(f"\n  >>> gpt-4-1-mini (EU) ...")
    eu_report, eu_time, eu_code = call_report(EU, test["transcript"], test["visit_type"])
    print(f"      HTTP {eu_code} | {eu_time:.1f}s")

    print(f"\n  >>> gpt-5-mini (US) ...")
    us_report, us_time, us_code = call_report(US, test["transcript"], test["visit_type"])
    print(f"      HTTP {us_code} | {us_time:.1f}s")

    # Speed comparison
    if eu_time > 0 and us_time > 0:
        ratio = us_time / eu_time
        faster = "gpt-4-1-mini" if eu_time < us_time else "gpt-5-mini"
        print(f"\n  ⏱  SPEED: gpt-4-1-mini={eu_time:.1f}s | gpt-5-mini={us_time:.1f}s | {faster} is {abs(ratio - 1) * 100:.0f}% faster")
    
    # Report length comparison
    eu_len = len(eu_report) if isinstance(eu_report, str) else 0
    us_len = len(us_report) if isinstance(us_report, str) else 0
    print(f"  📝 LENGTH: gpt-4-1-mini={eu_len} chars | gpt-5-mini={us_len} chars")

    # Print reports side by side (truncated)
    print(f"\n  --- gpt-4-1-mini report ---")
    print(textwrap.indent(eu_report[:1200] if isinstance(eu_report, str) else str(eu_report), "  "))
    print(f"\n  --- gpt-5-mini report ---")
    print(textwrap.indent(us_report[:1200] if isinstance(us_report, str) else str(us_report), "  "))

print(f"\n{SEP}")
print("  DONE — All tests completed")
print(SEP)
