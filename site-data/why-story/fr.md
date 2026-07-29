## Pourquoi j’ai créé ForgePlay

ForgePlay n’a pas été créé pour copier CrossOver.

Pour les personnes qui souhaitent exécuter des jeux Windows sur macOS sans machine virtuelle ni installation Windows séparée, CrossOver a longtemps été la seule référence commerciale sérieuse. Des interfaces gratuites et des projets communautaires ont existé, mais presque aucun concurrent équivalent n’a réuni dans un même produit un développement durable, une assistance technique, une installation automatisée, une configuration propre à chaque jeu et des couches de traduction graphique.

C’est précisément cette absence de concurrence qui me dérangeait.

Lorsqu’un produit n’a pas de rival sérieux, il n’est pas contraint de réexaminer ses propres postulats. Les utilisateurs ne disposent d’aucune solution comparable vers laquelle se tourner, si bien que la pression pour proposer de nouvelles fonctions en premier ou remplacer une architecture vieillissante diminue. Je pense que CrossOver s’est installé dans une forme de complaisance au sein de cet environnement.

Je ne voulais pas m’en tenir à la critique. Si une autre architecture était possible, je devais la construire et en publier suffisamment pour permettre à d’autres d’examiner le code et de tester le résultat. C’est ainsi qu’est né ForgePlay.

### J’ai vu ce qui arrive lorsque la concurrence disparaît

J’ai été fonctionnaire en Corée du Sud. Dans ce pays, un poste dans la fonction publique est souvent qualifié de **bol de riz en fer** : un emploi comportant très peu de risques de licenciement et, sauf faute grave, assuré jusqu’à la retraite.

Pendant une dizaine d’années, j’ai principalement travaillé dans des services que la plupart des gens cherchaient à éviter. J’ai vu directement ce qui se passe lorsqu’une organisation perd à la fois la pression concurrentielle et toute menace réelle pesant sur sa survie.

Lorsqu’un problème survenait, répartir les responsabilités passait avant sa résolution. Reporter une décision et préserver la procédure existante était plus sûr que de changer quoi que ce soit. L’organisation ne disparaissait pas lorsque les mêmes échecs se répétaient, et l’absence d’amélioration menaçait rarement les moyens de subsistance d’un individu. Le changement devenait donc une tâche facultative que quelqu’un devait se porter volontaire pour assumer.

J’en suis venu à penser que la diligence individuelle ne pouvait pas résoudre ce problème. La structure façonnait les comportements. J’ai finalement quitté cette carrière prétendument sûre parce que je n’avais plus foi en cette culture.

La leçon que j’en ai tirée est simple :

> **Sans menace pour la survie, le changement devient facultatif. Sans concurrence, l’amélioration ralentit et les problèmes non résolus deviennent la norme.**

De même que la pression de survie entraîne l’évolution, la pression concurrentielle oblige les produits à changer. Sans solution de remplacement crédible, aucun rival ne vérifie si l’approche actuelle reste suffisamment bonne, et les raisons d’améliorer avant d’y être contraint sont moins nombreuses.

Je me suis posé la même question à propos de CrossOver :

> **CodeWeavers s’est-il accommodé du modèle existant parce qu’il n’avait aucun concurrent équivalent ?**

Ma réponse est oui.

### Restituer 95 % n’efface pas les 5 % restants

CodeWeavers contribue à Wine depuis de nombreuses années. L’entreprise a intégré en amont une part considérable du travail développé pour CrossOver et a joué un rôle important dans la pérennité de l’écosystème Wine. Cette contribution mérite d’être reconnue.

Mais CodeWeavers fait également la promotion de CrossOver avec cette affirmation :

> **« 95 % du code Wine que nous développons pour CrossOver est reversé au projet Wine pour la communauté open source. »**[^crossover-95]

Cette phrase est à la fois une fierté et un aveu. **Quatre-vingt-quinze pour cent ne font pas cent.** Selon le propre chiffre de CodeWeavers, une partie du code Wine développé pour CrossOver n’intègre pas l’amont commun de Wine.

Ce point ne doit pas être brouillé. La LGPL exige la fourniture du code source correspondant lorsqu’un binaire Wine modifié est distribué, mais elle n’impose pas que chaque modification soit fusionnée dans l’amont de WineHQ.[^lgpl] Si les cinq pour cent restants figurent dans l’archive des sources libres de CrossOver, ce seul fait ne prouve pas une violation de la LGPL.

Mais **respecter le minimum légal n’est pas la même chose que restituer le travail aux biens communs.**

Publier une archive du code source pour chaque version n’équivaut pas à placer les changements en amont, où ils peuvent être examinés, maintenus et testés contre les régressions dans le cadre du projet partagé. Tout projet indépendant souhaitant utiliser un correctif conservé en aval doit le trouver, l’isoler, le réadapter aux nouvelles versions de Wine et le valider de nouveau. L’existence du code source quelque part ne signifie pas que la communauté puisse effectivement le réutiliser et le faire progresser.

CodeWeavers affirme également sur sa page consacrée à l’open source qu’il développe son travail Wine directement par rapport à l’amont et qu’il l’y soumet en premier.[^crossover-95] Il devrait donc être facile de rendre compte des cinq pour cent restants. Ont-ils été refusés en amont, étaient-ils trop spécifiques au produit pour être fusionnés, sont-ils encore en préparation ou ont-ils été volontairement conservés comme travail en aval propre à CrossOver ? Le discours commercial actuel célèbre les 95 %, mais ne dit rien sur le contenu des 5 % restants ni sur les raisons de leur maintien hors de l’amont commun.

> **CodeWeavers est libre de bâtir une activité sur les biens communs de Wine, mais ne peut pas demander qu’on le félicite de restituer « l’essentiel » de ses améliorations tout en traitant le reste comme s’il n’existait pas. Si l’affirmation porte sur 95 %, les 5 % restants exigent des explications.**

Fournir le code source correspondant parce que la LGPL l’exige relève de la **conformité à la licence**. Placer les changements dans l’amont partagé afin que chacun puisse les examiner, les maintenir et construire dessus relève de la **réciprocité envers l’écosystème**. Ce ne sont pas les mêmes choses et elles ne doivent pas être présentées comme telles.

L’objection ne tient pas au fait que CodeWeavers gagne de l’argent grâce à une interface propriétaire, une base de données de compatibilité ou des composants commerciaux sous licences distinctes. Elle tient au fait que l’entreprise s’appuie sur le travail de la communauté Wine, conserve certaines de ses propres améliorations et connaissances opérationnelles comme avantage produit, puis invoque son « soutien à l’open source » comme si cela mettait fin au débat.

Les contributions passées ne placent pas le produit CrossOver actuel à l’abri de toute critique. Contribuer à Wine ne fait pas davantage de l’architecture de CrossOver la réponse définitive aux jeux Windows sur macOS.

CrossOver est un produit payant. Les clients ne paient pas uniquement pour des binaires Wine. Ils paient pour un modèle d’exécution propre à macOS, une validation jeu par jeu, une assistance en cas de panne et la gestion des régressions après les mises à jour.

La difficulté de mise en œuvre, le coût de l’assurance qualité et les effectifs limités sont de véritables contraintes. La concurrence change les priorités à l’intérieur de ces contraintes. Avec un concurrent équivalent, une intégration plus poussée aux capacités propres à macOS serait devenue bien plus tôt une fonction centrale du produit.

CrossOver pouvait préserver son architecture existante sans perdre sa position, car aucun rival équivalent n’existait. Je pense que cet environnement a rendu sa complaisance possible.

### Le mode Jeu était prévisible et réalisable, mais il est resté négligé

Un produit vendu pour jouer sur macOS aurait dû considérer l’intégration au mode Jeu de macOS comme une tâche d’ingénierie évidente.

Le mode Jeu accorde au jeu une priorité accrue sur les ressources CPU et GPU, réduit les interférences des tâches en arrière-plan et diminue la latence des manettes et appareils audio sans fil. Il ne s’agit pas simplement d’une fonction destinée à augmenter le nombre maximal d’images par seconde, mais d’un mécanisme du système d’exploitation qui améliore la régularité des images et la réactivité.[^game-mode]

CrossOver 26 documente en détail D3DMetal, DXMT, DXVK, DLSS, MSync et d’autres fonctions graphiques et de synchronisation. Il ne présente pas l’intégration du mode Jeu pour chaque titre comme une fonction du produit.[^crossover-settings]

ForgePlay crée un **Game Host** macOS indépendant pour chaque jeu. Ce Game Host lance Wine et le véritable processus du jeu Windows, puis possède et gère toute la session de jeu du début à la fin. Lorsque le jeu passe en plein écran, macOS reconnaît ce Game Host comme étant le jeu et active normalement le mode Jeu.

Il ne s’agit pas d’une simple catégorie de jeu cosmétique rattachée au lanceur ForgePlay. Le processus qui possède réellement la session de jeu participe au modèle d’exécution des jeux de macOS.

L’architecture n’est pas secrète et ne nécessite aucun privilège exceptionnel. C’est une conception qu’un produit de jeu pour macOS aurait raisonnablement pu envisager. Je l’ai envisagée, mise en œuvre et j’ai vérifié qu’elle fonctionne.

CodeWeavers développe un produit Wine commercial depuis des décennies et n’en a pourtant jamais fait une fonction de son produit.

Si l’entreprise n’a jamais envisagé cette conception, son architecture s’était figée. Si elle l’a envisagée puis écartée, ses priorités s’étaient figées. Le résultat est le même.

> **Ce n’était pas techniquement impossible. Cela n’avait simplement pas besoin d’être fait en priorité tant qu’aucun concurrent n’imposait le sujet.**

Avec un rival équivalent, cette lacune n’aurait pas survécu longtemps. Si un produit avait mis en avant son intégration au mode Jeu, l’autre aurait dû répondre par une meilleure mise en œuvre. Mais il n’y avait aucun rival équivalent et personne ne contraignait CodeWeavers à avancer.

J’appelle cela de la complaisance rendue possible par une faible concurrence.

Le Game Host de ForgePlay n’est pas une réponse rhétorique à ce constat. C’est une réponse qui fonctionne.

### macOS doit être traité comme une plateforme de jeu, pas seulement comme un endroit où lancer Wine

Un produit de jeu pour macOS ne devrait pas s’arrêter après avoir lancé des processus Wine.

Chaque jeu devrait être géré comme un système d’exécution unique comprenant :

- un cycle de vie d’application propre à chaque jeu ;
- le mode Jeu ;
- les transitions vers le plein écran ;
- les préfixes et réglages de lancement ;
- les moteurs graphiques ;
- les variables d’environnement ;
- les journaux et diagnostics ; et
- le nettoyage après la fermeture du jeu.

ForgePlay organise ces éléments autour d’un Game Host propre à chaque jeu. Il ne traite pas macOS comme un simple bureau sur lequel Wine se trouve fonctionner. Son principe fondamental consiste à gérer les jeux Windows au sein du modèle d’exécution des jeux de macOS.

### Ne pas transférer la responsabilité de la compatibilité aux utilisateurs et à la communauté

Un produit de compatibilité payant devrait assumer la responsabilité des tests de régression pour chaque jeu et définir clairement le périmètre de l’assistance officielle.

Il ne devrait pas s’appuyer sur les évaluations des utilisateurs, les conseils de la communauté, des DLL externes, des modifications du registre et des configurations manuelles pour résoudre les échecs de lancement, les problèmes vidéo, les saccades ou les défauts d’entrée, de son et de lanceur, puis présenter le résultat comme si la compatibilité avait été assurée par le produit lui-même.

La base de données de compatibilité de CodeWeavers réunit des contributions du personnel et de la communauté, tandis que ses pages de conseils précisent que les informations provenant de la communauté et des Advocates ne constituent pas une assistance officielle.[^compatibility-database] Le partage des connaissances est utile. Le problème commence lorsqu’il relègue au second plan les obligations d’assurance qualité et d’assistance d’un produit payant.

Les signalements des utilisateurs doivent compléter l’assurance qualité, pas la remplacer. Les solutions de contournement communautaires doivent compléter les correctifs officiels, pas masquer leur absence.

Au minimum, CodeWeavers devrait distinguer clairement les états suivants :

- le jeu fonctionne avec les réglages par défaut de CrossOver ;
- le jeu nécessite une configuration officielle de CodeWeavers ;
- le jeu nécessite une solution de contournement communautaire ;
- le jeu nécessite une DLL externe ou un correctif non officiel ;
- la vidéo, les entrées, le réseau ou d’autres fonctions restent défaillants ; et
- le jeu ne fonctionne que dans une version précise ou a subi une régression.

Si un jeu n’est pas pris en charge, il doit être indiqué comme tel. Si une intervention manuelle est nécessaire, cette condition doit être affichée aussi clairement que l’évaluation de compatibilité.

Lorsqu’un client paie le produit puis doit diagnostiquer lui-même la panne, modifier les réglages, installer des correctifs externes et réinjecter le résultat dans la base de données, la frontière entre la responsabilité du produit et le travail communautaire non rémunéré a déjà disparu.

### La compatibilité ne doit pas rester une boîte noire

La compatibilité n’est pas établie parce qu’un exécutable s’ouvre une fois. Une véritable compatibilité inclut la vidéo, les entrées, le son, le réseau, la régularité des images, une fermeture propre et la reproductibilité après les mises à jour.

La base de données privée de CrossOver consacrée aux configurations par jeu et aux moteurs graphiques constitue un choix commercial légitime.[^crossover-proprietary] Ce choix a pour prix l’opacité. Les utilisateurs ne peuvent souvent pas déterminer exactement quels réglages ont été appliqués, pourquoi un jeu fonctionne ou échoue, ni ce qui a changé après une mise à jour.

ForgePlay sépare l’environnement d’exécution et la configuration de chaque jeu. Il consigne la configuration appliquée et les journaux d’exécution afin de rendre reproductibles aussi bien les réussites que les échecs. Il ne prétend pas que tous les jeux fonctionnent. Au lieu de dissimuler les échecs, il privilégie une structure qui permet de les retracer et d’en faire le point de départ de la prochaine correction.

La compatibilité devrait être un résultat technique vérifiable, et non une simple note attribuée par une entreprise.

### Se prémunir contre la privatisation de fait de Wine, pourtant open source

Wine lui-même reste open source. Il ne s’agit pas d’accuser CodeWeavers de s’être légalement approprié Wine ou d’en avoir fermé le code source.

Mais une privatisation de fait n’exige pas que le code source devienne entièrement fermé. Une entreprise peut s’appuyer sur l’amont communautaire tout en dispersant les derniers éléments qui créent l’écart entre les produits dans des correctifs en aval, des données privées, des composants propriétaires et des droits de redistribution opaques. Le cœur juridique peut rester ouvert alors même que le contrôle pratique se concentre entre les mains d’une seule entreprise.

Le problème réside dans une structure où la capacité réelle à utiliser Wine pour jouer sur macOS se concentre dans :

- des modifications de Wine propres à CrossOver qui restent en dehors de l’amont commun et que les autres implémentations doivent extraire, réadapter et valider à nouveau ;
- des composants propriétaires ;
- des données privées de compatibilité par jeu ;
- des droits de redistribution commerciale qui ne sont pas publiquement confirmés ;
- des priorités de développement contrôlées par une seule entreprise ; et
- des systèmes d’installation et d’exécution gérés par cette entreprise.

L’affirmation des 95 % de CodeWeavers ne répond pas à cette préoccupation. Elle confirme qu’une partie du travail sur Wine lié à CrossOver reste hors de l’amont commun. Même lorsque ce code peut être légalement réutilisé à partir de l’archive source d’une version, le coût de sa recherche, de son portage vers la version actuelle de Wine et des tests de régression est reporté sur les développeurs indépendants. CodeWeavers dispose déjà du résultat intégré et testé dans son propre produit.

> **Même un cœur ouvert peut devenir une douve privée lorsque le dernier kilomètre reste en aval, propriétaire, verrouillé par les données ou opaque.**

Si cette structure se fige, Wine peut rester ouvert sous forme de code source tandis que sa valeur pratique pour le grand public devient dépendante d’un seul produit commercial. Une couche opérationnelle fermée devient alors le seul accès réaliste à un cœur open source.

C’est ce que j’entends par la **privatisation de fait de Wine, pourtant open source**. Je ne prétends pas que sa propriété juridique a été transférée. Je critique une structure qui absorbe librement les fondations communautaires tout en laissant les modifications, les données et les capacités d’intégration qui créent l’écart pratique entre les produits difficiles à reproduire pour les autres implémentations.

CodeWeavers compte peut-être parmi les contributeurs les plus importants de Wine, mais n’est pas propriétaire de son écosystème. Des années de contribution n’autorisent pas une entreprise à déterminer par défaut l’orientation et les priorités du jeu sous Wine sur macOS.

Une entreprise qui vante la valeur de l’open source devrait également respecter les projets indépendants et les concurrents qui utilisent les mêmes fondations pour expérimenter, construire des architectures différentes et critiquer le produit établi. Elle ne devrait pas se servir de sa contribution de 95 % comme d’un bouclier pour écarter l’écart concurrentiel créé par les 5 % restants, les connaissances privées en matière de compatibilité et les composants propriétaires.

Wine se renforce lorsque plusieurs implémentations et modèles de distribution se font concurrence. Une structure dans laquelle un seul produit commercial reste la seule réponse pratique affaiblit l’ouverture qui fait la valeur de Wine.

### Le problème n’est pas l’intégration de GPTK, mais la transparence des autorisations commerciales

ForgePlay intègre lui aussi Wine et GPTK. Le regroupement de GPTK ou de D3DMetal dans une même distribution n’est donc pas l’objet de la critique.

Le fichier `License.rtf` inclus dans la distribution de GPTK intégrée à ForgePlay limite la redistribution sous cette licence de développement à des fins non commerciales.[^gptk-license] ForgePlay est actuellement publié sans prix d’achat, et son accès n’est conditionné ni à un paiement ni à un soutien financier. Il ne présente pas GPTK ou D3DMetal comme des composants open source appartenant à ForgePlay : ils restent des composants tiers distincts, régis par la licence qui les accompagne.

CodeWeavers déclare publiquement que CrossOver 26 inclut D3DMetal 3.0, et CrossOver est vendu comme un produit payant.[^crossover26]

Il reste donc une question directe à poser à CodeWeavers :

> **CodeWeavers dispose-t-il d’un accord commercial distinct ou d’une autorisation de redistribution permettant d’inclure D3DMetal dans les versions payantes de CrossOver et de le distribuer aux utilisateurs finaux ?**

Personne ne demande de tarifs confidentiels ni le contrat complet. Si cette autorisation existe, CodeWeavers peut en confirmer l’existence et préciser les produits et versions auxquels elle s’applique.

Rien ne justifie que la base commerciale de la redistribution d’un composant tiers majeur au sein d’un produit payant reste publiquement indéterminée. Si CodeWeavers se présente comme un défenseur de l’open source et de la liberté logicielle, l’entreprise devrait offrir au moins un minimum de transparence sur les autorisations commerciales qui sous-tendent sa propre distribution.

ForgePlay s’applique le même principe. Si son modèle de distribution ou de revenus change, les licences attachées aux versions de GPTK et de D3DMetal utilisées seront réexaminées. ForgePlay ne présumera pas de droits que la licence applicable ne lui accorde pas.

### Pourquoi ForgePlay est open source

ForgePlay est open source parce qu’une critique doit pouvoir être vérifiée.

Si j’affirme que CrossOver est devenu complaisant faute de concurrence sérieuse, je dois d’abord montrer qu’une autre architecture peut réellement fonctionner.

- L’architecture du Game Host doit pouvoir être examinée.
- Le processus dans lequel le mode Jeu s’active doit pouvoir être vérifié.
- Les préfixes et réglages propres à chaque jeu doivent être visibles.
- Les affirmations en matière de performances et de compatibilité doivent pouvoir être contrôlées à l’aide du code et des journaux.
- Les échecs et les limites ne doivent pas être dissimulés.

Le projet ForgePlay officiel reste dirigé par son mainteneur et n’accepte actuellement pas de contributions de code. Sous réserve des licences applicables, chacun peut examiner le code source, créer un fork ou développer une implémentation distincte.

CrossOver a choisi un produit commercial comprenant des composants propriétaires. ForgePlay choisit de publier son propre code, d’exposer l’architecture et le résultat, et de permettre aux utilisateurs de les comparer directement.

ForgePlay n’échappe pas à ce principe. Pour chaque modification de Wine, il doit indiquer quels changements ont atteint l’amont et lesquels restent propres à ForgePlay, puis publier les raisons, l’ensemble complet des correctifs et les éléments de compilation de tout ce qui demeure en aval. **Il n’utilisera pas l’argument « l’essentiel est ouvert » pour masquer les exceptions qui comptent.**

### S’il n’existe aucun concurrent, créons-en un

J’ai quitté une carrière qualifiée de bol de riz en fer parce que j’avais déjà vu comment une organisation se fige lorsque les problèmes non résolus n’ont aucun coût pour sa survie.

Je ne voulais pas accepter la même complaisance comme une fatalité dans le logiciel.

La contribution de CodeWeavers à Wine mérite le respect. Elle ne fait pas de l’architecture actuelle de CrossOver la réponse définitive pour l’écosystème. Toute organisation ou tout produit qui reste trop longtemps la référence sans concurrence significative finit par se figer.

Le chiffre de 95 % avancé par CodeWeavers témoigne d’une contribution. Il témoigne aussi d’une limite : les 5 % restants demeurent hors de l’amont commun. Lorsque cet écart s’ajoute à des données de compatibilité privées, à des composants propriétaires et à une autorisation commerciale opaque pour D3DMetal, un cœur open source peut passer de fondation commune à douve commerciale contrôlée par une seule entreprise.

L’implémentation du Game Host et du mode Jeu en est un exemple concret. Un développeur indépendant a identifié et mis en œuvre une architecture que CodeWeavers n’a jamais transformée en fonction de son produit. Elle n’était pas techniquement impossible. Il n’était simplement pas nécessaire de la rendre prioritaire tant qu’aucun concurrent équivalent n’existait.

La dépendance envers les solutions de contournement communautaires, la concentration des connaissances pratiques dans des données privées et le manque de clarté sur les droits de redistribution commerciale reflètent le même problème fondamental. Lorsque la concurrence est faible, la pression pour expliquer et améliorer l’est également.

Cette insatisfaction est l’une des principales raisons d’être de ForgePlay.

> **Si l’acteur établi n’y a pas pensé parce qu’il n’avait aucun concurrent, j’y penserai.**  
> **Si l’acteur établi ne l’a pas construit parce qu’il n’avait aucun concurrent, je le construirai.**

ForgePlay n’est pas un slogan dirigé contre CrossOver. C’est la mise en œuvre de choix que CrossOver n’a pas faits, publiée afin que le résultat puisse être testé au grand jour.

> **Si l’absence de concurrence a interrompu le progrès, la réponse consiste à créer de la concurrence.**

ForgePlay existe pour lancer cette concurrence.

[^crossover-95]: CodeWeavers, [CrossOver](https://www.codeweavers.com/crossover), [Open Source](https://www.codeweavers.com/open-source) et [code source de CrossOver](https://www.codeweavers.com/crossover/source). CodeWeavers affirme que 95 % du code Wine développé pour CrossOver est reversé au projet Wine, déclare séparément que le travail sur Wine est d’abord soumis en amont et fournit des archives de sources libres propres à chaque version.
[^lgpl]: Projet GNU, [Licence publique générale limitée GNU, version 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html), en particulier les sections 2, 4 et 6. La licence exige le code source correspondant pour le code de bibliothèque modifié qui est distribué, mais n’impose ni son acceptation ni sa fusion dans un dépôt amont particulier.
[^game-mode]: Apple, [Utiliser le mode Jeu sur Mac](https://support.apple.com/en-us/105118) et [`LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode).
[^crossover-settings]: CodeWeavers, [Réglages avancés de CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^compatibility-database]: CodeWeavers, [La base de données de compatibilité](https://support.codeweavers.com/en_US/the-compatibility-database) et [avis relatif aux conseils CrossOver](https://www.codeweavers.com/compatibility/crossover/tips/codeweavers-crossover/bottles-and-installing).
[^crossover-proprietary]: CodeWeavers, [Open Source](https://www.codeweavers.com/open-source) et [Réglages avancés de CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^gptk-license]: Le fichier `License.rtf` inclus dans la distribution officielle du Game Porting Toolkit intégrée à ForgePlay, sections 1, 2.A et 2.C.
[^crossover26]: CodeWeavers, [annonce de CrossOver 26](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac).
