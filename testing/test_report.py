#!/usr/bin/env python3
"""Test the /report endpoint with a large Czech medical transcript."""
import urllib.request, urllib.error, json, time, ssl

ctx = ssl.create_default_context()
url = 'https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io'
token = '_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I'

# Large transcript simulating ~1000 words / 20min recording
transcript = (
    "Dobry den, pane doktore. Dobry den, posad'te se prosim. Tak co vas k nam privadi? "
    "No, ja mam takove problemy, uz asi tri tydny me boli zada, hlavne tady dole v krizi, "
    "a nekdy to vystreluie do leve nohy. Rozumim. A kdy presne to zacalo? Bylo to po nejake "
    "namaze nebo to prislo samo? No, tak ja jsem zvedal tezkou krabici v praci, a najednou "
    "jsem ucitil takove skubnuti v zadech, a od te doby to mam. Jasne. A ta bolest, jak byste "
    "ji popsal na stupnici od jedne do deseti? Tak normalne je to tak ctyri pet, ale kdyz se "
    "predklonim nebo rano kdyz vstavam, tak to je i sedm osm. V noci me to taky budi. "
    "Berete na to nejake leky? Jo, beru ibuprofen, tri sta miligramu, asi dvakrat denne, ale "
    "moc to nepomaha. Zkousel jsem i takovy zahrivaci krem, ale taky nic moc. "
    "Mate nejake dalsi onemocneni? Lecite se s necim? No, mam vysoky tlak, na to beru ten "
    "ramipril, pet miligramu rano. A pak mam zvyseny cholesterol, na to beru atorvastatin "
    "dvacet miligramu. A v rodine, mel nekdo problemy se zady, s plotenkami? Tata mel operaci "
    "plotenky, kdyz mu bylo padesat. A mama ma revma. Dobre. Alergie na nejake leky? "
    "Na penicilin, mel jsem vyrazku po nem. Kourite? Pijete alkohol? Nekourim, prestal jsem "
    "pred peti lety. Pivo si dam tak dve trikrat tydne. A v praci, co delate? Pracuji ve "
    "skladu, takze zvedam tezke veci, asi dvacet tricet kilo denne. "
    "Tak se na vas podivame. Svleknete se prosim do pasu. Lehnete si sem na lehatko. "
    "Tak, tady kdyz zmacknu, boli to? Ano, tady to boli hodne. Au, to je presne to misto. "
    "A kdyz zvednu nohu takhle, boli to? Jo, to tahne celou nohu dozadu. "
    "Dobre. Lasegue pozitivni vlevo na triceti stupnich. Tak oblechnete se. "
    "Na zaklade vysetreni se jedna o lumbalgie s radikulopatii L5 vlevo, pravdepodobne pri "
    "protruzi disku L4 L5. Doporucuji magnetickou rezonanci bederni pateze k potvrzeni diagnozy. "
    "Predepisuji diklofenak sto miligramu denne, rozdelit na dve davky. "
    "Take predepisuji myorelaxans tizanidin dva miligramy na noc. Klidovy rezim, zadne zvedani "
    "tezkych predmetu minimalne dva tydny. Doporucuji navstevu rehabilitace, napisu vam zadanku. "
    "A kontrola u me za tri tydny, nebo drive pokud se stav zhorsi. "
    "Mate nejake dotazy? Ne? Tak nashledanou a at se brzy uzdravite. "
    "Jeste bych chtel zminit, ze pacient take udava obcasne brneni v leve noze, zejmena v "
    "oblasti palce a nartu. Citlivost na dotek v dermatomu L5 je snizena. Motorika plantiflexe "
    "a dorziflexe zachovana. Achillova slacha vybavna symetricky. Patelarni reflex vybavny "
    "symetricky. Babinski negativni bilateralne. Chuze po spickach i po patach bez obtizi. "
    "Pacient je orientovan, spolupracujici, afebrilni. TK sto ctyricet lomeno osmdesat pet, "
    "tepova frekvence sedmdesat dva za minutu, saturace devadesat osm procent. "
    "Bricho mekke, palpacne nebolestivne, peristaltika pritomna. Hlava a krk bez patologie. "
    "Dalsi vysetreni ukazalo, ze pacient ma take mirne otoky v oblasti kotnika vlevo. "
    "Periferni pulzace hmatna na obou dolnich koncetinach. Varikozity nepritomny. "
    "Kuzni pokryv bez patologickych zmen. Lymfaticke uzliny na krku, v axilach a trislich "
    "nehmatne. Stici zlaza nezvetsena. Hrudnik symetricky, dychani ciste, sklipkove, bez "
    "vedlejsich fenomu. Srdecni ozvy ohranicene, pravidelne, bez sumenu. "
    "Pacient udava, ze v poslednich dnech ma take obcasne bolesti hlavy, predevsim v oblasti "
    "cela, pulsujiciho charakteru. Bolesti hlavy hodnosti VAS tri. Zvysenou teplotu pacient "
    "neguje. Nauzeu a zvraceni neguje. Poruchy videni neguje. Poruchy sluchu neguje. "
    "Celkove se citi unaveny, spatne spi kvuli bolestem zad. "
    "Na zaklade komplexniho vysetreni doporucuji nasledujici plan: "
    "Magneticka rezonance bederni pateze. Laboratorni vysetreni: krevni obraz, CRP, sedimentace. "
    "Diklofenak 50mg 1-0-1 po jidle. Tizanidin 2mg 0-0-1. Omeprazol 20mg 1-0-0 jako gastroprotekce. "
    "Klidovy rezim, pracovni neschopnost na dva tydny. Rehabilitace po ziskani vysledku MR. "
    "Kontrola za tri tydny s vysledky vysetreni."
)

data = json.dumps({
    'transcript': transcript,
    'language': 'cs',
    'visit_type': 'default'
}).encode('utf-8')

headers_dict = {
    'Authorization': f'Bearer {token}',
    'Content-Type': 'application/json'
}

print(f'Transcript: {len(transcript)} chars, ~{len(transcript.split())} words')
print('Sending report request...')
start = time.time()
try:
    req = urllib.request.Request(f'{url}/report', data=data, headers=headers_dict, method='POST')
    resp = urllib.request.urlopen(req, timeout=120, context=ctx)
    result = json.loads(resp.read().decode('utf-8'))
    report = result.get('report', '')
    elapsed = time.time() - start
    print(f'SUCCESS in {elapsed:.1f}s')
    print(f'Report: {len(report)} chars')
    print('--- First 500 chars ---')
    print(report[:500])
except urllib.error.HTTPError as e:
    elapsed = time.time() - start
    body = e.read().decode('utf-8')
    print(f'HTTP {e.code} in {elapsed:.1f}s: {body[:500]}')
except Exception as e:
    elapsed = time.time() - start
    print(f'FAILED in {elapsed:.1f}s: {type(e).__name__}: {e}')
