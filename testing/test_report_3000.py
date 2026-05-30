import urllib.request, json, time

BACKEND = "https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io"
TOKEN = "_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I"

# ~3000 word Czech medical transcript (detailed diabetology follow-up)
transcript = """
Doktor: Dobrý den, pane Nováku, pojďte dál, posaďte se. Jak se máte?
Pacient: Dobrý den, pane doktore. No, celkem dobře, ale mám pár věcí, co bych chtěl probrat.
Doktor: Samozřejmě, tak povídejte. Naposledy jste tu byl před třemi měsíci na kontrole diabetu, takže se podíváme, jak se vám daří s kompenzací a jestli je něco nového.
Pacient: Tak za prvé, ty cukry se mi zdají celkem stabilní, měřím si je pravidelně, ráno nalačno mám většinou kolem šesti až sedmi, po jídle tak osm devět, občas deset, ale to jen když se trochu přejím.
Doktor: To zní docela dobře. A co glykovaný hemoglobin, máte výsledky z laboratoře?
Pacient: Ano, byl jsem minulý týden na odběrech, tady mám papír.
Doktor: Tak se podíváme. Glykovaný hemoglobin padesát tři milimolů na mol, to je mírné zlepšení oproti minule, kdy byl padesát šest. Takže jdeme správným směrem. Lipidový profil celkový cholesterol pět celých dva, LDL tři celých jedna, HDL jedna celá čtyři, triglyceridy jedna celá osm. Ten LDL je pořád trochu vyšší, než bychom chtěli.
Pacient: A co s tím? Beru přece ten statin.
Doktor: Ano, berete atorvastatin dvacet miligramů jednou denně. Vzhledem k tomu, že máte diabetes a ten LDL je stále nad třemi, měli bychom zvážit navýšení dávky na čtyřicet miligramů. Jak to snášíte, máte nějaké bolesti svalů nebo jiné problémy?
Pacient: Ne, žádné bolesti svalů nemám, snáším to dobře.
Doktor: Výborně, tak to navýšíme. Dále vidím kreatinin osmdesát pět, odhadovaná glomerulární filtrace devadesát dva, to je v normě. Jaterní testy ALT třicet dva, AST dvacet osm, taky v pořádku.
Pacient: To jsem rád. Ještě bych chtěl říct, že mě poslední dobou trápí taková bolest v pravém koleni. Hlavně když jdu do schodů nebo vstávám ze židle.
Doktor: Jak dlouho to trvá?
Pacient: Asi tak měsíc, měsíc a půl. Začalo to postupně, nebyla tam žádná úraz ani nic.
Doktor: A zhoršuje se to?
Pacient: Trochu jo, hlavně ráno je to tuhé, ale po rozchození se to trochu uvolní. Večer po práci je to zase horší.
Doktor: Máte nějaký otok nebo zarudnutí?
Pacient: Tak občas mi přijde, že je to koleno trochu oteklé, ale zarudlé ne.
Doktor: Dobře, podívám se na to. Vyšetřím vám koleno. Tak si lehněte na lehátko. Takže palpačně citlivost v oblasti mediálního kompartmentu, mírný výpotek, rozsah pohybu nula až sto třicet stupňů, lehká krepitace při flexi, stabilita vazu zachována, McMurray negativní. Vypadá to na počínající gonartrózu, vzhledem k věku a zátěži. Doporučím rentgen kolena pro potvrzení a předepíšu vám něco na bolest.
Pacient: A co můžu dělat, kromě léků?
Doktor: Určitě pomohou cviky na posílení stehenního svalstva, můžete zkusit rehabilitaci, pošlu vás na fyzioterapii. Důležité je udržovat přiměřený pohyb, ale vyhnout se nadměrné zátěži, jako je běhání po tvrdém povrchu nebo dřepy s velkou zátěží. Můžete plavat, jezdit na kole, to kolenu nevadí.
Pacient: Dobře, to zkusím. A ještě jedna věc, manželka mi říkala, že v noci chrápu a občas se mi zastaví dech. Ona se toho děsí.
Doktor: To je důležitá informace. Jak dlouho to pozoruje?
Pacient: Říkala, že už delší dobu, možná půl roku, ale poslední měsíce je to horší. A já se přiznám, že se ráno budím unavený, i když spím sedm osm hodin.
Doktor: Máte přes den ospalost? Usínáte třeba u televize nebo za jízdy?
Pacient: U televize jo, to usnu skoro pokaždé. Za jízdy ne, to ne, ale cítím se takový malátný.
Doktor: Váha dnes kolik?
Pacient: Sto dva kilo, jsem sto osmdesát tři centimetrů. Přibral jsem asi tři kila za poslední rok.
Doktor: Takže BMI asi třicet celých pět. To je obezita prvního stupně. Klinicky to vypadá na podezření na syndrom obstrukční spánkové apnoe. Doporučím vám polysomnografické vyšetření na spánkové laboratoři, abychom to objektivizovali. Mezitím bych doporučil zkusit spát na boku, vyhnout se alkoholu večer a ideálně začít s redukcí váhy.
Pacient: Jo, s tou váhou, to vím, že bych měl zhubnout, ale je to těžké. V práci jsem celý den na nohou, přijdu domů unavený a nemám moc motivaci cvičit.
Doktor: Rozumím. Co vaše strava? Dodržujete diabetickou dietu?
Pacient: Snažím se, ale přiznám se, že o víkendech to trochu povolím. Manželka vaří dobře a já nemám sílu odmítat.
Doktor: Zkuste aspoň zmenšit porce a vynechat přidávání. A co pití? Alkohol?
Pacient: Tak pivo si dám, dvě tři za týden, o víkendu někdy čtyři. Tvrdý alkohol ne.
Doktor: To je na hraně, zkuste to omezit na maximálně jedno dvě piva za týden, hlavně kvůli těm trigliceridům a kaloriím. A kouření?
Pacient: Nekouřím, přestal jsem před deseti lety.
Doktor: Výborně, to je skvělé. Pojďme teď projít celou medikaci. Co berete pravidelně?
Pacient: Tak metformin tisíc miligramů dvakrát denně, ráno a večer k jídlu. Pak ten atorvastatin dvacet miligramů, ten budu brát čtyřicet teď. Ramipril pět miligramů jednou denně na tlak. A aspirin sto miligramů jednou denně.
Doktor: A inzulín žádný?
Pacient: Ne, inzulín neužívám.
Doktor: Dobře. A co se týče očí, kdy jste byl naposledy u oftalmologa?
Pacient: To je asi rok a půl, měl bych jít znova.
Doktor: Určitě, s diabetem je potřeba kontrola očního pozadí jednou ročně. Napíšu vám doporučení. A nohy? Máte nějaké problémy s citlivostí, brnění, pálení?
Pacient: Občas mi brnějí prsty na nohou, hlavně večer. Ale není to nic hrozného.
Doktor: To může být počínající diabetická neuropatie. Vyšetřím vám citlivost. Takže monofilament test snížená citlivost na obou nohách v oblasti palce a přednoží, vibrační čití snížené bilaterálně na kotníku, Achillovy reflexy symetrické, oslabené. Pedální pulzace hmatné bilaterálně. Kůže suchá, bez ulcerací, bez deformit.
Pacient: A co s tím bráněním?
Doktor: Je to opravdu počínající polyneuropatie. Nejdůležitější je dobrá kompenzace diabetu, to zpomalí progresi. Dále péče o nohy, denně si je kontrolujte, používejte hydratační krém, noste pohodlné boty. Pokud by se to zhoršovalo, můžeme zvážit léčbu na neuropatickou bolest, ale zatím bych vyčkal.
Pacient: Dobře, budu si dávat pozor.
Doktor: Ještě se zeptám na psychiku. Jak se cítíte po duševní stránce? Máte depresivní nálady, úzkosti?
Pacient: No, občas jsem takový podrážděný, hlavně když jsem unavený. Ale deprese bych neřekl, náladu mám celkem stabilní.
Doktor: A stres v práci?
Pacient: To jo, v práci je to náročné, jsem stavbyvedoucí, mám zodpovědnost za celou partu, termíny tlačí. Ale zvládám to.
Doktor: Rozumím. Změny v rodinné situaci?
Pacient: Ne, tam je klid, dcera se vdala loni, syn studuje vysokou, s manželkou jsme spolu třicet let, jsme spokojení.
Doktor: Výborně. Pojďme shrnout. Udělám vám teď ještě kontrolu krevního tlaku a pulzu.
Pacient: Jasně.
Doktor: Takže krevní tlak sto třicet osm lomeno osmdesát šest milimetrů rtuti, pulz sedmdesát šest tepů za minutu, pravidelný. Saturace devadesát sedm procent. To je trochu vyšší ten tlak, ideálně bychom chtěli pod sto třicet lomeno osmdesát.
Pacient: A co s tím?
Doktor: Zvážíme navýšení ramiprilu na deset miligramů, nebo přidání dalšího antihypertenziva. Zkusíme nejdřív ten ramipril navýšit. Jak ho snášíte? Nemáte suchý kašel?
Pacient: Ne, kašel nemám.
Doktor: Dobře, tak zvýšíme na deset miligramů. Ještě se zeptám, jaké máte další chronické nemoci kromě diabetu a hypertenze?
Pacient: Mám ten zvýšený cholesterol a před pěti lety jsem měl ledvinový kámen, ale od té doby se nic neopakovalo.
Doktor: Operace jste měl nějaké?
Pacient: Apendektomii v osmnácti a pak artroskopii levého kolena před deseti lety. Nic vážného.
Doktor: A v rodině? Rodiče, sourozenci, nějaké závažné nemoci?
Pacient: Táta měl infarkt v šedesáti pěti, zemřel na druhý infarkt v sedmdesáti dvou. Máma měla diabetes druhého typu, léčila se inzulínem. Sestra je zdravá, bratr má taky diabetes a vysoký tlak.
Doktor: Děkuji. Takže shrnu dnešní nález a plán. Diabetes mellitus druhého typu s mírně zlepšenou kompenzací, glykovaný hemoglobin padesát tři, pokračujeme v metforminu tisíc miligramů dvakrát denně. Dyslipidémie, navyšujeme atorvastatin na čtyřicet miligramů. Hypertenze, navyšujeme ramipril na deset miligramů, kontrola tlaku za měsíc. Podezření na gonartrózu pravého kolena, odesílám na rentgen a fyzioterapii, na bolest předepíšu diklofenak gel lokálně a paracetamol při silnější bolesti, maximálně tři gramy denně. Podezření na obstrukční spánkovou apnoe, odesílám na polysomnografii. Počínající diabetická polyneuropatie, zatím observace, péče o nohy. Doporučení k oftalmologovi na kontrolu očního pozadí. Redukce váhy, omezení alkoholu.
Pacient: To je toho hodně.
Doktor: Ano, ale nic z toho není akutně závažné. Důležité je postupně pracovat na životním stylu a dodržovat medikaci. Na kontrolu přijďte za tři měsíce, předtím si udělejte odběry glykovaného hemoglobinu, lipidového profilu a ledvinných funkcí. A pokud by se cokoliv zhoršilo, zavolejte a přijďte dřív.
Pacient: Dobře, děkuju moc, pane doktore.
Doktor: Není zač, nashledanou a držte se.
Pacient: Nashledanou.
Doktor: A ještě k těm předpisům. Metformin tisíc miligramů, dva krát denně, pokračovat beze změny, preskripce na tři měsíce. Atorvastatin čtyřicet miligramů, jednou denně večer, nově, recept na tři měsíce. Ramipril deset miligramů, jednou denně ráno, navýšení z pěti miligramů, recept na tři měsíce. Aspirin sto miligramů, jednou denně, pokračovat, preskripce na tři měsíce. Diklofenak gel, lokálně na koleno tři krát denně dle potřeby, recept na jeden měsíc. Paracetamol pětset miligramů, jeden až dva při bolesti, maximálně šest tablet denně, recept na jeden měsíc.
Pacient: A ty žádanky?
Doktor: Ano, připravím žádanku na rentgen pravého kolena, žádanku na polysomnografii v spánkové laboratoři a doporučení k oftalmologovi plus žádanku na fyzioterapii kolena. Všechno budete mít připravené na recepci.
Pacient: Výborně, ještě jednou děkuju.
Doktor: Rád jsem pomohl, přeji hezký den.
"""

word_count = len(transcript.split())
print(f"Transcript: {len(transcript)} chars, ~{word_count} words")

url = f"{BACKEND}/report"
headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {TOKEN}"
}
data = json.dumps({"transcript": transcript, "language": "cs"}).encode()

req = urllib.request.Request(url, data=data, headers=headers)
start = time.time()
try:
    resp = urllib.request.urlopen(req, timeout=180)
    body = json.loads(resp.read())
    elapsed = time.time() - start
    report = body.get("report", "")
    print(f"SUCCESS in {elapsed:.1f}s")
    print(f"Report: {len(report)} chars")
    print(f"--- First 500 chars ---")
    print(report[:500])
except urllib.error.HTTPError as e:
    elapsed = time.time() - start
    print(f"HTTP ERROR {e.code} in {elapsed:.1f}s")
    print(f"Body: {e.read().decode()[:500]}")
except Exception as e:
    elapsed = time.time() - start
    print(f"ERROR in {elapsed:.1f}s: {e}")
