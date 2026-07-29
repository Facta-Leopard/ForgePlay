## Warum ich ForgePlay entwickelt habe

ForgePlay wurde nicht entwickelt, um CrossOver zu kopieren.

Für Menschen, die Windows-Spiele unter macOS ohne virtuelle Maschine oder separate Windows-Installation ausführen möchten, war CrossOver lange der einzige ernstzunehmende kommerzielle Bezugspunkt. Es gab freie Frontends und Community-Projekte, doch kaum einen gleichwertigen Wettbewerber, der kontinuierliche Entwicklung, technischen Support, automatisierte Installation, spielspezifische Konfiguration und Grafik-Übersetzungsschichten in einem Produkt vereinte.

Genau dieser fehlende Wettbewerb störte mich.

Wenn ein Produkt keinen ernsthaften Rivalen hat, muss es seine eigenen Grundannahmen nicht neu hinterfragen. Den Nutzern fehlt eine vergleichbare Alternative; dadurch sinkt der Druck, neue Funktionen zuerst zu entwickeln oder eine veraltete Architektur zu ersetzen. Ich glaube, dass CrossOver in diesem Umfeld selbstzufrieden geworden ist.

Ich wollte es nicht bei Kritik belassen. Wenn eine andere Architektur möglich war, musste ich sie entwickeln und genug davon veröffentlichen, damit andere den Code prüfen und das Ergebnis testen können. So begann ForgePlay.

### Ich habe gesehen, was geschieht, wenn Wettbewerb verschwindet

Ich war Beamter in Südkorea. Dort wird eine Stelle im öffentlichen Dienst oft als **eiserne Reisschüssel** bezeichnet: ein Beruf mit äußerst geringem Kündigungsrisiko und, sofern kein schwerwiegendes Fehlverhalten vorliegt, einer Beschäftigung bis zum Ruhestand.

Etwa zehn Jahre lang arbeitete ich vorwiegend in Abteilungen, die die meisten Menschen mieden. Dort erlebte ich unmittelbar, was geschieht, wenn einer Organisation sowohl der Wettbewerbsdruck als auch jede ernsthafte Bedrohung ihres Fortbestands fehlt.

Wenn Probleme auftraten, wurde zuerst die Verantwortung verteilt, statt das Problem zu lösen. Eine Entscheidung aufzuschieben und am bestehenden Verfahren festzuhalten, war sicherer, als etwas zu verändern. Die Organisation verschwand nicht, wenn sich dieselben Fehler wiederholten, und der Lebensunterhalt Einzelner war durch ausbleibende Verbesserungen kaum je bedroht. Veränderung wurde damit zu freiwilliger Zusatzarbeit, die irgendjemand auf sich nehmen musste.

Ich kam zu dem Schluss, dass sich dieses Problem nicht durch den Fleiß Einzelner lösen ließ. Die Struktur formte das Verhalten. Schließlich verließ ich die vermeintlich sichere Laufbahn, weil ich das Vertrauen in diese Kultur verloren hatte.

Die Lehre daraus ist für mich einfach:

> **Ohne eine Bedrohung des Fortbestands wird Veränderung zur freiwilligen Aufgabe. Ohne Wettbewerb verlangsamt sich die Verbesserung, und ungelöste Probleme werden zum Alltag.**

So wie Überlebensdruck die Evolution antreibt, zwingt Wettbewerbsdruck Produkte zur Veränderung. Ohne eine glaubwürdige Alternative gibt es keinen Rivalen, der prüft, ob der bisherige Ansatz noch gut genug ist, und weniger Anlass, etwas zu verbessern, bevor man dazu gezwungen wird.

Dieselbe Frage stellte ich mir bei CrossOver:

> **Hat sich CodeWeavers mit dem bestehenden Modell eingerichtet, weil es keinen gleichwertigen Wettbewerber gab?**

Meine Antwort lautet: ja.

### Wer 95 Prozent zurückgibt, lässt die übrigen 5 Prozent nicht verschwinden

CodeWeavers trägt seit vielen Jahren zu Wine bei. Das Unternehmen hat einen erheblichen Teil der für CrossOver entwickelten Arbeit in das Upstream-Projekt eingebracht und eine wichtige Rolle beim Erhalt des Wine-Ökosystems gespielt. Dieser Beitrag verdient Anerkennung.

CodeWeavers wirbt für CrossOver jedoch auch mit folgender Aussage:

> **„95 % des Wine-Codes, den wir für CrossOver entwickeln, fließen für die Open-Source-Community in das Wine-Projekt zurück.“**[^crossover-95]

Dieser Satz ist zugleich Eigenlob und Eingeständnis. **Fünfundneunzig Prozent sind nicht hundert.** Nach den eigenen Angaben von CodeWeavers wird ein Teil des für CrossOver entwickelten Wine-Codes nicht Bestandteil des gemeinsamen Wine-Upstreams.

Dieser Punkt darf nicht verwischt werden. Die LGPL verlangt bei der Verteilung einer veränderten Wine-Binärdatei die Bereitstellung des zugehörigen Quellcodes, verpflichtet aber nicht dazu, jede Änderung in den WineHQ-Upstream zu übernehmen.[^lgpl] Falls die verbleibenden fünf Prozent im FOSS-Quellarchiv von CrossOver enthalten sind, beweist diese Tatsache allein keinen Verstoß gegen die LGPL.

Doch **die gesetzlichen Mindestanforderungen zu erfüllen ist nicht dasselbe, wie Arbeit an die Allgemeinheit zurückzugeben.**

Für jede Veröffentlichung ein Quellarchiv bereitzustellen ist nicht gleichbedeutend damit, Änderungen upstream einzubringen, wo sie als Teil des gemeinsamen Projekts geprüft, gepflegt und auf Regressionen getestet werden können. Einen downstream verbliebenen Patch muss jedes unabhängige Projekt, das ihn verwenden möchte, zunächst finden, isolieren, auf neuere Wine-Versionen übertragen und erneut validieren. Dass Quellcode irgendwo vorhanden ist, bedeutet nicht, dass die Community ihn in der Praxis wiederverwenden und weiterentwickeln kann.

CodeWeavers erklärt auf seiner Open-Source-Seite außerdem, Wine-Arbeiten direkt gegen den Upstream zu entwickeln und zuerst dort einzureichen.[^crossover-95] Dann sollte sich leicht erklären lassen, was es mit den verbleibenden fünf Prozent auf sich hat. Wurden sie upstream abgelehnt, waren sie zu produktspezifisch, befinden sie sich noch in Vorbereitung oder wurden sie bewusst als reine CrossOver-Downstream-Arbeit zurückgehalten? Das aktuelle Marketing feiert die 95 Prozent, sagt aber nichts darüber, was die anderen 5 Prozent enthalten oder weshalb sie außerhalb des gemeinsamen Upstreams bleiben.

> **CodeWeavers darf auf der gemeinsamen Grundlage Wine ein Unternehmen aufbauen. Es kann jedoch nicht Anerkennung dafür verlangen, den „größten Teil“ seiner Verbesserungen zurückzugeben, und den Rest zugleich behandeln, als gäbe es ihn nicht. Wer 95 Prozent für sich beansprucht, muss über die anderen 5 Prozent Rechenschaft ablegen.**

Den zugehörigen Quellcode bereitzustellen, weil die LGPL es verlangt, ist **Lizenzkonformität**. Änderungen in den gemeinsamen Upstream einzubringen, damit alle sie prüfen, pflegen und darauf aufbauen können, ist **Gegenseitigkeit im Ökosystem**. Beides ist nicht dasselbe und sollte auch nicht so vermarktet werden.

Der Einwand lautet nicht, dass CodeWeavers mit einer proprietären Oberfläche, einer Kompatibilitätsdatenbank oder gesondert lizenzierten kommerziellen Komponenten Geld verdient. Der Einwand lautet, dass das Unternehmen auf der Arbeit der Wine-Community aufbaut, einen Teil seiner eigenen Verbesserungen und seines betrieblichen Wissens als Produktvorteil zurückhält und sich anschließend auf seine „Unterstützung von Open Source“ beruft, als sei damit jede Diskussion beendet.

Frühere Beiträge entziehen das heutige CrossOver-Produkt nicht der Kritik. Ebenso wenig macht ein Beitrag zu Wine die Architektur von CrossOver zur endgültigen Antwort für Windows-Spiele unter macOS.

CrossOver ist ein kostenpflichtiges Produkt. Kunden bezahlen nicht bloß für Wine-Binärdateien. Sie bezahlen für ein macOS-spezifisches Ausführungsmodell, die Prüfung einzelner Spiele, Hilfe bei Problemen und das Management von Regressionen nach Updates.

Schwierige Implementierung, QA-Kosten und begrenztes Personal sind reale Einschränkungen. Wettbewerb verändert die Prioritäten innerhalb dieser Einschränkungen. Mit einem gleichwertigen Konkurrenten wäre eine tiefere Einbindung macOS-spezifischer Funktionen sehr viel früher zu einem zentralen Produktmerkmal geworden.

CrossOver konnte seine bestehende Architektur beibehalten, ohne seine Stellung zu verlieren, weil kein gleichwertiger Rivale existierte. Ich glaube, dass dieses Umfeld seine Selbstzufriedenheit ermöglicht hat.

### Der Spielemodus war absehbar und umsetzbar – und blieb dennoch unerledigt

Ein Produkt, das für Gaming unter macOS verkauft wird, hätte die Integration des macOS-Spielemodus als naheliegende Entwicklungsaufgabe behandeln müssen.

Der Spielemodus räumt einem Spiel bei CPU- und GPU-Ressourcen eine höhere Priorität ein, reduziert Störungen durch Hintergrundprozesse und senkt die Latenz drahtloser Controller und Audiogeräte. Er dient nicht bloß dazu, die maximale Bildrate zu erhöhen, sondern ist ein Mechanismus des Betriebssystems für gleichmäßigere Bildausgabe und bessere Reaktionsfähigkeit.[^game-mode]

CrossOver 26 dokumentiert D3DMetal, DXMT, DXVK, DLSS, MSync und weitere Grafik- und Synchronisierungsfunktionen ausführlich. Eine spielspezifische Integration des Spielemodus wird dort nicht als Produktfunktion ausgewiesen.[^crossover-settings]

ForgePlay erstellt für jedes Spiel einen eigenständigen macOS-**Game Host**. Dieser startet Wine und den eigentlichen Windows-Spielprozess und übernimmt anschließend die gesamte Spielsitzung von Anfang bis Ende. Wechselt das Spiel in den Vollbildmodus, erkennt macOS diesen Game Host als Spiel und aktiviert den Spielemodus regulär.

Dabei handelt es sich nicht um eine kosmetische Spielkategorie, die dem ForgePlay-Launcher angeheftet wurde. Der Prozess, dem die tatsächliche Spielsitzung gehört, nimmt am Spielausführungsmodell von macOS teil.

Die Architektur ist nicht geheim und benötigt keine außergewöhnlichen Berechtigungen. Ein Produkt für macOS-Gaming hätte dieses Design vernünftigerweise in Betracht ziehen können. Ich habe es erwogen, umgesetzt und seine Funktionsfähigkeit überprüft.

CodeWeavers entwickelt seit Jahrzehnten ein kommerzielles Wine-Produkt und hat daraus dennoch keine Produktfunktion gemacht.

Wenn das Unternehmen dieses Design nie erwogen hat, war seine Produktarchitektur erstarrt. Wenn es das Design erwogen und verworfen hat, waren seine Prioritäten erstarrt. Das Ergebnis bleibt dasselbe.

> **Technisch unmöglich war es nicht. Solange kein Wettbewerber Druck ausübte, musste es lediglich nicht als Erstes erledigt werden.**

Mit einem gleichwertigen Rivalen hätte diese Lücke nicht lange bestanden. Hätte ein Produkt mit Spielemodus-Integration geworben, hätte das andere mit einer besseren Umsetzung antworten müssen. Doch es gab keinen gleichwertigen Rivalen und niemand zwang CodeWeavers zum Handeln.

Ich nenne das Selbstzufriedenheit, ermöglicht durch schwachen Wettbewerb.

Der Game Host von ForgePlay ist keine rhetorische Antwort auf dieses Urteil, sondern eine funktionierende.

### macOS sollte als Spieleplattform behandelt werden und nicht nur als Ort, an dem Wine startet

Ein Produkt für macOS-Gaming sollte nicht beim Starten von Wine-Prozessen stehen bleiben.

Jedes Spiel sollte als ein zusammenhängendes Ausführungssystem verwaltet werden. Dazu gehören:

- ein eigener Anwendungslebenszyklus je Spiel;
- der Spielemodus;
- Vollbildübergänge;
- Prefixe und Starteinstellungen;
- Grafik-Backends;
- Umgebungsvariablen;
- Protokolle und Diagnosedaten; sowie
- die Bereinigung nach dem Beenden des Spiels.

ForgePlay ordnet diese Elemente um einen spielspezifischen Game Host an. macOS wird nicht als bloße Desktop-Umgebung betrachtet, auf der Wine zufällig läuft. Das grundlegende Design verwaltet Windows-Spiele innerhalb des macOS-Modells zur Ausführung von Spielen.

### Die Verantwortung für Kompatibilität darf nicht auf Nutzer und Community abgewälzt werden

Ein kostenpflichtiges Kompatibilitätsprodukt sollte die Verantwortung für Regressionstests einzelner Spiele und für eine klare Abgrenzung des offiziellen Supports übernehmen.

Es sollte sich bei Startfehlern, fehlerhafter Videowiedergabe, Ruckeln sowie Problemen mit Eingabe, Audio oder Launchern nicht auf Nutzerbewertungen, Community-Tipps, externe DLLs, Änderungen an der Registry und manuelle Konfiguration verlassen und das Ergebnis anschließend so darstellen, als hätte das Produkt selbst die Kompatibilität geliefert.

Die Kompatibilitätsdatenbank von CodeWeavers vereint Beiträge von Mitarbeitern und Community, während auf den Tippseiten darauf hingewiesen wird, dass Informationen der Community und der Advocates keinen offiziellen Support darstellen.[^compatibility-database] Geteiltes Wissen ist nützlich. Problematisch wird es, wenn dadurch die QA- und Supportpflichten eines kostenpflichtigen Produkts in den Hintergrund rücken.

Nutzerberichte sollten QA ergänzen, nicht ersetzen. Behelfslösungen der Community sollten offizielle Korrekturen ergänzen und nicht deren Fehlen verdecken.

Mindestens sollte CodeWeavers klar zwischen folgenden Zuständen unterscheiden:

- Das Spiel funktioniert mit den Standardeinstellungen von CrossOver.
- Das Spiel benötigt eine offizielle Konfiguration von CodeWeavers.
- Das Spiel benötigt eine Behelfslösung der Community.
- Das Spiel benötigt eine externe DLL oder einen inoffiziellen Patch.
- Video, Eingabe, Netzwerk oder andere Funktionen bleiben defekt.
- Das Spiel funktioniert nur mit einer bestimmten Version oder ist von einer Regression betroffen.

Wird ein Spiel nicht unterstützt, sollte es als nicht unterstützt gekennzeichnet werden. Ist ein manueller Umweg erforderlich, sollte diese Bedingung ebenso deutlich angezeigt werden wie die Kompatibilitätsbewertung.

Wenn ein Kunde für das Produkt bezahlt und den Fehler anschließend selbst diagnostizieren, Einstellungen ändern, externe Patches installieren und das Ergebnis wieder in die Datenbank eintragen muss, ist die Grenze zwischen Produktverantwortung und unbezahlter Community-Arbeit bereits zusammengebrochen.

### Kompatibilität darf keine Blackbox bleiben

Kompatibilität ist nicht schon dann gegeben, wenn sich eine ausführbare Datei einmal öffnen lässt. Echte Kompatibilität umfasst Video, Eingabe, Audio, Netzwerk, gleichmäßige Bildausgabe, sauberes Beenden und die Reproduzierbarkeit nach Updates.

Die private Datenbank von CrossOver für spielspezifische Konfigurationen und Grafik-Backends ist eine legitime geschäftliche Entscheidung.[^crossover-proprietary] Ihr Preis ist mangelnde Transparenz. Nutzer können häufig nicht genau feststellen, welche Einstellungen angewendet wurden, weshalb ein Spiel funktioniert oder scheitert und was sich nach einem Update verändert hat.

ForgePlay trennt Ausführungsumgebung und Konfiguration für jedes Spiel. Es zeichnet die angewendete Konfiguration und Laufzeitprotokolle auf, damit Erfolge ebenso wie Fehler reproduzierbar sind. ForgePlay behauptet nicht, dass jedes Spiel funktioniert. Anstatt Fehler zu verbergen, priorisiert es eine Struktur, in der sie nachvollziehbar sind und zur nächsten Korrektur führen können.

Kompatibilität sollte ein überprüfbares technisches Ergebnis sein und nicht bloß eine von einem Unternehmen vergebene Bewertung.

### Der faktischen Privatisierung des quelloffenen Wine vorbeugen

Wine selbst bleibt Open Source. Dies ist kein Vorwurf, CodeWeavers habe sich Wine rechtlich angeeignet oder dessen Quellcode geschlossen.

Eine faktische Privatisierung erfordert jedoch keine vollständige Schließung des Quellcodes. Ein Unternehmen kann auf dem Upstream der Community aufbauen und zugleich die letzten Bausteine, die den Produktvorsprung erzeugen, auf Downstream-Patches, private Daten, proprietäre Komponenten und intransparente Weiterverteilungsrechte verteilen. Der rechtliche Kern kann offen bleiben, während sich die praktische Kontrolle bei einem Unternehmen konzentriert.

Problematisch ist eine Struktur, in der sich die praktische Fähigkeit, Wine für Spiele unter macOS einzusetzen, auf Folgendes konzentriert:

- CrossOver-spezifische Wine-Änderungen, die außerhalb des gemeinsamen Upstreams verbleiben und von anderen Implementierungen extrahiert, übertragen und erneut validiert werden müssen;
- proprietäre Komponenten;
- private spielspezifische Kompatibilitätsdaten;
- kommerzielle Weiterverteilungsrechte, die öffentlich nicht bestätigt sind;
- Entwicklungsprioritäten unter der Kontrolle eines einzigen Unternehmens; und
- von diesem Unternehmen verwaltete Installations- und Ausführungssysteme.

Die 95-Prozent-Aussage von CodeWeavers beantwortet diese Sorge nicht. Sie bestätigt, dass ein Teil der CrossOver-bezogenen Wine-Arbeit außerhalb des gemeinsamen Upstreams verbleibt. Selbst wenn dieser Code aus einem Quellarchiv einer Veröffentlichung rechtmäßig wiederverwendet werden kann, werden die Kosten für das Auffinden, die Übertragung auf eine aktuelle Wine-Version und die Regressionstests auf unabhängige Entwickler verlagert. CodeWeavers verfügt in seinem Produkt bereits über das integrierte und getestete Ergebnis.

> **Auch ein offener Kern kann zum privaten Schutzgraben werden, wenn die letzte Meile downstream, proprietär, datengesperrt oder intransparent bleibt.**

Verfestigt sich diese Struktur, kann Wine in Quellform offen bleiben, während sein praktischer Wert für gewöhnliche Nutzer von einem einzigen kommerziellen Produkt abhängig wird. Eine geschlossene operative Schicht wird dann zum einzigen realistischen Zugang zu einem quelloffenen Kern.

Das meine ich mit der **faktischen Privatisierung des quelloffenen Wine**. Damit behaupte ich nicht, dass das rechtliche Eigentum übertragen wurde. Ich kritisiere eine Struktur, die das Fundament der Community frei aufnimmt, während Änderungen, Daten und Integrationsfähigkeiten, die den praktischen Produktvorsprung schaffen, für andere Implementierungen nur schwer reproduzierbar bleiben.

CodeWeavers mag zu den wichtigsten Mitwirkenden an Wine gehören, ist aber nicht der Eigentümer des Wine-Ökosystems. Jahrelange Beiträge berechtigen ein einzelnes Unternehmen nicht dazu, Richtung und Prioritäten für Wine-Gaming unter macOS standardmäßig zu bestimmen.

Ein Unternehmen, das für den Wert von Open Source wirbt, sollte auch unabhängige Projekte und Konkurrenten respektieren, die auf derselben Grundlage experimentieren, andere Architekturen entwickeln und das etablierte Produkt kritisieren. Es sollte den 95-prozentigen Beitrag nicht als Schutzschild verwenden, um die Wettbewerbslücke abzutun, die durch die übrigen 5 Prozent, privates Kompatibilitätswissen und proprietäre Komponenten entsteht.

Wine wird stärker, wenn mehrere Implementierungen und Vertriebsmodelle miteinander konkurrieren. Eine Struktur, in der ein einziges kommerzielles Produkt die einzige praktikable Antwort bleibt, schwächt jene Offenheit, der Wine seinen Wert verdankt.

### Das Problem ist nicht die Bündelung von GPTK, sondern die Transparenz kommerzieller Rechte

Auch ForgePlay bündelt Wine und GPTK. Die Kritik richtet sich daher nicht dagegen, GPTK oder D3DMetal gemeinsam mit anderen Komponenten zu vertreiben.

Die `License.rtf` der mit ForgePlay gebündelten GPTK-Distribution begrenzt die Weiterverteilung unter dieser Entwicklerlizenz auf nicht kommerzielle Zwecke.[^gptk-license] ForgePlay wird derzeit ohne Kaufpreis veröffentlicht, und der Zugang ist weder von einer Zahlung noch von einer Förderung abhängig. GPTK und D3DMetal werden nicht als quelloffene Komponenten im Eigentum von ForgePlay dargestellt. Sie bleiben separate Komponenten Dritter, für die die jeweils mitgelieferte Lizenz gilt.

CodeWeavers erklärt öffentlich, dass CrossOver 26 D3DMetal 3.0 enthält, und CrossOver wird als kostenpflichtiges Produkt verkauft.[^crossover26]

Damit bleibt eine direkte Frage an CodeWeavers:

> **Verfügt CodeWeavers über eine gesonderte kommerzielle Vereinbarung oder Weiterverteilungsgenehmigung, die es erlaubt, D3DMetal in kostenpflichtige CrossOver-Versionen aufzunehmen und an Endnutzer zu verteilen?**

Niemand verlangt vertrauliche Preisangaben oder den vollständigen Vertrag. Wenn diese Berechtigung besteht, kann CodeWeavers ihre Existenz bestätigen und angeben, für welche Produkte und Versionen sie gilt.

Es gibt keinen Grund, die kommerzielle Grundlage für die Weiterverteilung einer wichtigen Drittanbieterkomponente in einem kostenpflichtigen Produkt öffentlich ungeklärt zu lassen. Wenn CodeWeavers sich als Unterstützer von Open Source und Softwarefreiheit präsentiert, sollte das Unternehmen zumindest ein Mindestmaß an Transparenz über die kommerziellen Rechte seiner eigenen Distribution schaffen.

ForgePlay legt denselben Maßstab an sich selbst an. Ändert sich sein Vertriebs- oder Erlösmodell, werden die Lizenzen der jeweils verwendeten GPTK- und D3DMetal-Versionen erneut geprüft. ForgePlay wird keine Rechte voraussetzen, die von der geltenden Lizenz nicht eingeräumt werden.

### Warum ForgePlay Open Source ist

ForgePlay ist Open Source, weil Kritik überprüfbar sein sollte.

Wenn ich behaupte, dass CrossOver ohne ernsthaften Wettbewerb selbstzufrieden geworden ist, muss ich zuerst zeigen, dass eine andere Architektur tatsächlich funktionieren kann.

- Die Game-Host-Architektur sollte überprüfbar sein.
- Der Prozess, in dem der Spielemodus aktiviert wird, sollte nachvollziehbar sein.
- Spielspezifische Prefixe und Einstellungen sollten sichtbar sein.
- Leistungs- und Kompatibilitätsaussagen sollten anhand von Code und Protokollen überprüfbar sein.
- Fehler und Einschränkungen sollten nicht verborgen werden.

Das offizielle ForgePlay-Projekt wird weiterhin vom Maintainer geführt und nimmt derzeit keine Codebeiträge an. Soweit es die jeweils geltenden Lizenzen erlauben, kann jeder den Quellcode prüfen, einen Fork erstellen oder eine eigenständige Implementierung entwickeln.

CrossOver entschied sich für ein kommerzielles Produkt mit proprietären Komponenten. ForgePlay entscheidet sich dafür, den eigenen Code zu veröffentlichen, Architektur und Ergebnis offenzulegen und den Nutzern den direkten Vergleich zu ermöglichen.

Auch ForgePlay ist von diesem Maßstab nicht ausgenommen. Bei jeder Wine-Änderung sollte angegeben werden, welche Änderungen upstream angekommen sind und welche ForgePlay-spezifisch bleiben. Für alles, was downstream verbleibt, sollten die Gründe, der vollständige Patchsatz und die Build-Materialien veröffentlicht werden. **ForgePlay wird nicht mit „das meiste ist offen“ jene Ausnahmen verschleiern, auf die es ankommt.**

### Wenn es keinen Wettbewerber gibt, baue einen

Ich verließ eine als eiserne Reisschüssel bezeichnete Laufbahn, weil ich bereits erlebt hatte, wie eine Organisation erstarrt, wenn ungelöste Probleme keine Kosten für ihr Überleben verursachen.

Ich wollte dieselbe Selbstzufriedenheit in der Softwarewelt nicht als unvermeidlich hinnehmen.

Der Beitrag von CodeWeavers zu Wine verdient Respekt. Er macht die heutige Architektur von CrossOver nicht zur endgültigen Antwort für das Ökosystem. Jede Organisation und jedes Produkt, das ohne ernsthaften Wettbewerb zu lange der Bezugspunkt bleibt, wird erstarren.

Die 95-Prozent-Angabe von CodeWeavers belegt einen Beitrag. Sie belegt zugleich eine Grenze: Die verbleibenden 5 Prozent bleiben außerhalb des gemeinsamen Upstreams. Kommen zu dieser Lücke private Kompatibilitätsdaten, proprietäre Komponenten und intransparente kommerzielle Rechte für D3DMetal hinzu, kann ein quelloffener Kern von einer gemeinsamen Grundlage in einen von einem Unternehmen kontrollierten kommerziellen Schutzgraben verwandelt werden.

Die Umsetzung von Game Host und Spielemodus ist ein konkretes Beispiel. Ein unabhängiger Entwickler hat eine Architektur erkannt und umgesetzt, die CodeWeavers nie zu einer Produktfunktion gemacht hat. Technisch unmöglich war sie nicht. Sie musste nur nicht priorisiert werden, solange kein gleichwertiger Wettbewerber existierte.

Die Abhängigkeit von Behelfslösungen der Community, die Konzentration praktischen Wissens in privaten Daten und die fehlende Klarheit über kommerzielle Weiterverteilungsrechte spiegeln dasselbe Grundproblem wider. Bei schwachem Wettbewerb ist auch der Druck schwach, zu erklären und zu verbessern.

Diese Unzufriedenheit ist einer der Hauptgründe für die Existenz von ForgePlay.

> **Wenn der etablierte Anbieter nicht daran gedacht hat, weil es keinen Wettbewerber gab, werde ich daran denken.**  
> **Wenn der etablierte Anbieter es nicht entwickelt hat, weil es keinen Wettbewerber gab, werde ich es entwickeln.**

ForgePlay ist kein gegen CrossOver gerichteter Slogan. Es ist die Umsetzung von Entscheidungen, die CrossOver nicht getroffen hat, veröffentlicht, damit das Ergebnis öffentlich getestet werden kann.

> **Wenn fehlender Wettbewerb den Fortschritt zum Stillstand gebracht hat, lautet die Antwort: Wettbewerb schaffen.**

ForgePlay existiert, um diesen Wettbewerb zu beginnen.

[^crossover-95]: CodeWeavers, [CrossOver](https://www.codeweavers.com/crossover), [Open Source](https://www.codeweavers.com/open-source) und [CrossOver-Quellcode](https://www.codeweavers.com/crossover/source). CodeWeavers erklärt, dass 95 % des für CrossOver entwickelten Wine-Codes in das Wine-Projekt zurückfließen, erklärt gesondert, dass Wine-Arbeiten zuerst upstream eingereicht werden, und stellt versionsbezogene FOSS-Quellarchive bereit.
[^lgpl]: GNU Project, [GNU Lesser General Public License, Version 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html), insbesondere Abschnitte 2, 4 und 6. Die Lizenz verlangt den zugehörigen Quellcode für verteilten, veränderten Bibliothekscode, aber keine Annahme oder Zusammenführung in einem bestimmten Upstream-Repository.
[^game-mode]: Apple, [Spielemodus auf dem Mac verwenden](https://support.apple.com/en-us/105118) und [`LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode).
[^crossover-settings]: CodeWeavers, [Erweiterte Einstellungen in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^compatibility-database]: CodeWeavers, [Die Kompatibilitätsdatenbank](https://support.codeweavers.com/en_US/the-compatibility-database) und [Hinweis zu CrossOver-Tipps](https://www.codeweavers.com/compatibility/crossover/tips/codeweavers-crossover/bottles-and-installing).
[^crossover-proprietary]: CodeWeavers, [Open Source](https://www.codeweavers.com/open-source) und [Erweiterte Einstellungen in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^gptk-license]: Die `License.rtf` der offiziellen, mit ForgePlay gebündelten Game-Porting-Toolkit-Distribution, Abschnitte 1, 2.A und 2.C.
[^crossover26]: CodeWeavers, [Ankündigung von CrossOver 26](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac).
