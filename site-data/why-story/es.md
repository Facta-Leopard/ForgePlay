## Por qué creé ForgePlay

ForgePlay no nació para copiar CrossOver.

Para quienes quieren ejecutar juegos de Windows en macOS sin una máquina virtual ni una instalación independiente de Windows, CrossOver ha sido durante mucho tiempo la única referencia comercial seria. Han existido interfaces gratuitas y proyectos comunitarios, pero casi ningún competidor equivalente ha reunido en un solo producto un desarrollo sostenido, soporte técnico, instalación automatizada, configuración por juego y capas de traducción gráfica.

Eso es precisamente lo que me preocupaba: la falta de competencia.

Cuando un producto no tiene un rival serio, no necesita volver a cuestionar sus propios supuestos. Los usuarios no tienen una alternativa comparable, por lo que disminuye la presión para crear antes nuevas funciones o sustituir una arquitectura envejecida. Creo que CrossOver se acomodó en ese entorno.

No quería limitarme a criticar. Si otra arquitectura era posible, tenía que construirla y publicar lo suficiente para que otras personas pudieran examinar el código y probar el resultado. Así comenzó ForgePlay.

### He visto lo que ocurre cuando desaparece la competencia

Fui funcionario público en Corea del Sur. Allí, un puesto en la administración suele describirse como un **cuenco de arroz de hierro**: un empleo con muy poco riesgo de despido y, salvo una falta grave, garantizado hasta la jubilación.

Durante unos diez años trabajé principalmente en departamentos que casi todo el mundo intentaba evitar. Vi de primera mano lo que sucede cuando una organización pierde tanto la presión competitiva como cualquier amenaza real para su supervivencia.

Cuando aparecía un problema, repartir responsabilidades importaba más que resolverlo. Aplazar una decisión y conservar el procedimiento existente era más seguro que cambiar algo. La organización no desaparecía aunque se repitieran los mismos fallos, y la falta de mejora rara vez ponía en peligro el sustento de una persona. Por eso, cambiar se convertía en una tarea opcional que alguien tenía que ofrecerse a asumir.

Llegué a la conclusión de que no era un problema que pudiera resolver la diligencia individual. La estructura moldeaba el comportamiento. Finalmente abandoné aquella carrera supuestamente segura porque había perdido la fe en esa cultura.

La lección que extraje es sencilla:

> **Sin una amenaza para la supervivencia, el cambio se vuelve opcional. Sin competencia, la mejora se ralentiza y los problemas sin resolver pasan a ser rutina.**

Así como la presión por sobrevivir impulsa la evolución, la presión competitiva obliga a cambiar a los productos. Sin una alternativa creíble, no existe un rival que ponga a prueba si el enfoque actual sigue siendo suficientemente bueno, y hay menos motivos para mejorar antes de verse obligado a hacerlo.

Me hice la misma pregunta sobre CrossOver:

> **¿Se acomodó CodeWeavers al modelo existente porque no tenía un competidor equivalente?**

Mi respuesta es sí.

### Devolver el 95 % no hace desaparecer el 5 % restante

CodeWeavers lleva muchos años contribuyendo a Wine. Ha incorporado al proyecto upstream una parte considerable del trabajo desarrollado para CrossOver y ha desempeñado un papel importante en la continuidad del ecosistema Wine. Esa aportación merece reconocimiento.

Pero CodeWeavers también promociona CrossOver con esta afirmación:

> **«El 95 % del código base de Wine que desarrollamos para CrossOver se devuelve al proyecto Wine para la comunidad de código abierto».**[^crossover-95]

La frase es al mismo tiempo una proclamación y una admisión. **El noventa y cinco por ciento no es el cien por cien.** Según la propia cifra de CodeWeavers, una parte del código de Wine desarrollado para CrossOver no se integra en el upstream compartido de Wine.

Conviene no desdibujar este punto. La LGPL exige entregar el código fuente correspondiente cuando se distribuye un binario de Wine modificado, pero no obliga a integrar todas las modificaciones en el upstream de WineHQ.[^lgpl] Si el cinco por ciento restante está incluido en el archivo de fuentes FOSS de CrossOver, ese hecho por sí solo no demuestra una infracción de la LGPL.

Pero **cumplir el mínimo legal no equivale a devolver el trabajo al patrimonio común.**

Publicar un archivo de código fuente para cada versión no es lo mismo que incorporar los cambios upstream, donde pueden revisarse, mantenerse y someterse a pruebas de regresión como parte del proyecto compartido. Todo proyecto independiente que quiera usar un parche conservado downstream tiene que encontrarlo, aislarlo, adaptarlo a versiones más recientes de Wine y validarlo de nuevo. Que el código fuente exista en algún lugar no significa que la comunidad pueda reutilizarlo y desarrollarlo de forma efectiva.

CodeWeavers afirma además en su página de código abierto que desarrolla su trabajo sobre Wine directamente contra upstream y que lo envía allí primero.[^crossover-95] En ese caso, debería ser fácil explicar el cinco por ciento restante. ¿Fue rechazado upstream, era demasiado específico del producto para integrarlo, sigue preparándose o se retuvo deliberadamente como trabajo downstream exclusivo de CrossOver? El marketing actual celebra el 95 %, pero no dice qué contiene el otro 5 % ni por qué permanece fuera del upstream compartido.

> **CodeWeavers es libre de construir un negocio sobre el patrimonio común de Wine, pero no puede pedir reconocimiento por devolver «la mayor parte» de sus mejoras mientras trata el resto como si no existiera. Si la afirmación es el 95 %, el otro 5 % exige una explicación.**

Proporcionar el código fuente correspondiente porque lo exige la LGPL es **cumplimiento de la licencia**. Incorporar los cambios al upstream compartido para que todos puedan revisarlos, mantenerlos y construir sobre ellos es **reciprocidad con el ecosistema**. No son lo mismo y no deberían presentarse comercialmente como si lo fueran.

La objeción no es que CodeWeavers gane dinero con una interfaz propietaria, una base de datos de compatibilidad o componentes comerciales con licencias independientes. La objeción es que construye sobre el trabajo de la comunidad Wine, conserva parte de sus propias mejoras y conocimientos operativos como ventaja de producto y después invoca el «apoyo al código abierto» como si eso cerrara la discusión.

Las contribuciones pasadas no sitúan al producto CrossOver actual fuera de toda crítica. Contribuir a Wine tampoco convierte la arquitectura de CrossOver en la respuesta definitiva para jugar a títulos de Windows en macOS.

CrossOver es un producto de pago. Sus clientes no pagan únicamente por binarios de Wine. Pagan por un modelo de ejecución específico para macOS, validación por juego, soporte cuando algo falla y gestión de regresiones después de las actualizaciones.

La dificultad de implementación, el coste del control de calidad y la escasez de personal son limitaciones reales. La competencia es lo que modifica las prioridades dentro de esas limitaciones. Con un competidor equivalente, una integración más profunda con las capacidades específicas de macOS se habría convertido mucho antes en una función central del producto.

CrossOver pudo conservar su arquitectura sin perder su posición porque no existía un rival equivalente. Creo que ese entorno hizo posible su complacencia.

### El modo Juego era previsible y viable, pero siguió sin hacerse

Un producto vendido para jugar en macOS debería haber considerado la integración con el modo Juego de macOS una tarea de ingeniería evidente.

El modo Juego otorga al juego mayor prioridad sobre los recursos de CPU y GPU, reduce las interferencias del trabajo en segundo plano y disminuye la latencia de mandos y dispositivos de audio inalámbricos. No es simplemente una función para elevar los FPS máximos; es un mecanismo del sistema operativo que mejora la estabilidad de los fotogramas y la capacidad de respuesta.[^game-mode]

CrossOver 26 documenta con detalle D3DMetal, DXMT, DXVK, DLSS, MSync y otras funciones gráficas y de sincronización. No presenta la integración del modo Juego por título como una función del producto.[^crossover-settings]

ForgePlay crea un **Game Host** independiente de macOS para cada juego. Ese Game Host inicia Wine y el proceso real del juego de Windows, y después posee y administra la sesión completa de principio a fin. Cuando el juego entra en pantalla completa, macOS reconoce al Game Host como el juego y activa el modo Juego con normalidad.

No se trata de una categoría de juego meramente decorativa añadida al lanzador de ForgePlay. El proceso que posee la sesión real participa en el modelo de ejecución de juegos de macOS.

La arquitectura no es secreta ni exige privilegios excepcionales. Es un diseño que cualquier producto de juegos para macOS podría haber considerado razonablemente. Yo lo consideré, lo implementé y verifiqué que funciona.

CodeWeavers lleva décadas desarrollando un producto comercial basado en Wine y aun así no convirtió esta idea en una función del producto.

Si nunca contempló el diseño, su arquitectura se había endurecido. Si lo contempló y lo descartó, se habían endurecido sus prioridades. El resultado es el mismo.

> **No era técnicamente imposible. Simplemente no había que hacerlo primero mientras ningún competidor obligara a afrontar el problema.**

Con un rival equivalente, esta carencia no habría durado mucho. Si un producto hubiera anunciado integración con el modo Juego, el otro habría tenido que responder con una implementación mejor. Pero no existía un rival equivalente y nadie obligaba a CodeWeavers a avanzar.

Eso es lo que llamo complacencia posibilitada por una competencia débil.

El Game Host de ForgePlay no es una respuesta retórica a ese juicio. Es una respuesta que funciona.

### macOS debe tratarse como plataforma de juegos, no solo como un lugar donde iniciar Wine

Un producto para jugar en macOS no debería detenerse después de crear procesos de Wine.

Cada juego debería administrarse como un único sistema de ejecución que incluya:

- un ciclo de vida de la aplicación para cada juego;
- el modo Juego;
- las transiciones a pantalla completa;
- los prefijos y ajustes de inicio;
- los backends gráficos;
- las variables de entorno;
- los registros y diagnósticos; y
- la limpieza posterior al cierre del juego.

ForgePlay organiza esos elementos alrededor de un Game Host propio para cada juego. No trata macOS como un escritorio en el que Wine simplemente se ejecuta. Su diseño básico consiste en administrar los juegos de Windows dentro del modelo de ejecución de juegos de macOS.

### No hay que trasladar la responsabilidad de compatibilidad a los usuarios y a la comunidad

Un producto de compatibilidad de pago debe responsabilizarse de las pruebas de regresión por juego y definir con claridad el alcance del soporte oficial.

No debería depender de valoraciones de usuarios, consejos de la comunidad, DLL externas, cambios en el registro y configuraciones manuales para resolver fallos de inicio, vídeo defectuoso, tirones y problemas de entrada, audio o lanzadores, y después presentar el resultado como si el propio producto hubiese proporcionado la compatibilidad.

La base de datos de compatibilidad de CodeWeavers combina aportaciones del personal y de la comunidad, mientras que sus páginas de consejos aclaran que la información comunitaria y de los Advocates no constituye soporte oficial.[^compatibility-database] Compartir conocimiento es útil. El problema comienza cuando eso relega a un segundo plano las obligaciones de control de calidad y soporte de un producto de pago.

Los informes de usuarios deben complementar el control de calidad, no sustituirlo. Las soluciones alternativas de la comunidad deben complementar las correcciones oficiales, no ocultar su ausencia.

Como mínimo, CodeWeavers debería diferenciar con claridad entre estos estados:

- el juego funciona con la configuración predeterminada de CrossOver;
- el juego necesita una configuración oficial de CodeWeavers;
- el juego necesita una solución alternativa de la comunidad;
- el juego necesita una DLL externa o un parche no oficial;
- el vídeo, la entrada, la red u otras funciones siguen fallando; y
- el juego solo funciona en una versión concreta o ha sufrido una regresión.

Si un juego no está soportado, debe marcarse como tal. Si requiere una solución manual, esa condición debe mostrarse con la misma relevancia que la valoración de compatibilidad.

Cuando un cliente paga por el producto y después tiene que diagnosticar el fallo, cambiar ajustes, instalar parches externos y devolver el resultado a la base de datos, la frontera entre la responsabilidad del producto y el trabajo comunitario no remunerado ya se ha derrumbado.

### La compatibilidad no debería seguir siendo una caja negra

La compatibilidad no queda demostrada porque un ejecutable se abra una sola vez. La compatibilidad real incluye vídeo, entrada, audio, red, estabilidad de fotogramas, cierre limpio y reproducibilidad después de las actualizaciones.

La base de datos privada de CrossOver para configuraciones por juego y backends gráficos es una decisión comercial legítima.[^crossover-proprietary] Su coste es la opacidad. A menudo los usuarios no pueden saber con exactitud qué ajustes se aplicaron, por qué un juego funciona o falla, ni qué cambió después de una actualización.

ForgePlay separa el entorno de ejecución y la configuración de cada juego. Registra la configuración aplicada y los datos de ejecución para que tanto los éxitos como los fallos puedan reproducirse. No afirma que todos los juegos funcionen. En lugar de ocultar los fallos, prioriza una estructura que permite rastrearlos y convertirlos en el punto de partida de la siguiente corrección.

La compatibilidad debería ser un resultado técnico que pueda inspeccionarse, no una simple puntuación emitida por una empresa.

### Hay que impedir la privatización de facto del Wine de código abierto

Wine sigue siendo código abierto. No estoy acusando a CodeWeavers de haberse apropiado legalmente de Wine ni de haber cerrado su código fuente.

Pero la privatización de facto no exige que el código se vuelva completamente cerrado. Una empresa puede construir sobre el upstream comunitario mientras dispersa las últimas piezas que crean la distancia entre productos entre parches downstream, datos privados, componentes propietarios y una autoridad de redistribución opaca. El núcleo legal puede seguir abierto mientras el control práctico se concentra en una sola empresa.

La preocupación es una estructura en la que la capacidad práctica de usar Wine para jugar en macOS se concentra en:

- cambios de Wine específicos de CrossOver que permanecen fuera del upstream compartido y que otras implementaciones deben extraer, adaptar y validar de nuevo;
- componentes propietarios;
- datos privados de compatibilidad por juego;
- derechos de redistribución comercial que no se han confirmado públicamente;
- prioridades de desarrollo controladas por una sola empresa; y
- sistemas de instalación y ejecución administrados por esa empresa.

La afirmación del 95 % de CodeWeavers no responde a esta preocupación. Confirma que parte del trabajo de Wine relacionado con CrossOver permanece fuera del upstream compartido. Incluso cuando ese código puede reutilizarse legalmente desde el archivo de fuentes de una versión, el coste de localizarlo, adaptarlo al Wine actual y probar las regresiones se traslada a los desarrolladores independientes. CodeWeavers ya posee dentro de su producto el resultado integrado y probado.

> **Un núcleo abierto puede convertirse en un foso privado si la última milla se mantiene downstream, propietaria, bloqueada por los datos u opaca.**

Si esa estructura se endurece, Wine puede seguir abierto como código fuente mientras su valor práctico para el usuario común pasa a depender de un único producto comercial. Una capa operativa cerrada se convierte en la única entrada realista a un núcleo de código abierto.

Eso es lo que quiero decir con la **privatización de facto del Wine de código abierto**. No es una afirmación de que se haya transferido la propiedad legal. Es una crítica a una estructura que absorbe libremente los cimientos comunitarios y, al mismo tiempo, hace difícil que otras implementaciones reproduzcan las modificaciones, los datos y la capacidad de integración que crean la diferencia práctica del producto.

CodeWeavers puede ser uno de los colaboradores más importantes de Wine, pero no es el propietario de su ecosistema. Años de contribuciones no conceden a una empresa el derecho a determinar por defecto la dirección y las prioridades de los juegos mediante Wine en macOS.

Una empresa que promueve el valor del código abierto también debería respetar a los proyectos independientes y competidores que utilizan la misma base para experimentar, crear arquitecturas distintas y criticar al producto establecido. No debería usar la contribución del 95 % como escudo para ignorar la brecha competitiva creada por el otro 5 %, el conocimiento privado de compatibilidad y los componentes propietarios.

Wine se fortalece cuando compiten varias implementaciones y modelos de distribución. Una estructura en la que un único producto comercial sigue siendo la única respuesta práctica debilita la apertura que da valor a Wine.

### El problema no es incluir GPTK, sino la transparencia sobre la autorización comercial

ForgePlay también incluye Wine y GPTK. Por tanto, la crítica no consiste en distribuir GPTK o D3DMetal dentro de un paquete combinado.

El archivo `License.rtf` incluido con la distribución de GPTK que acompaña a ForgePlay limita la redistribución bajo esa licencia para desarrolladores a fines no comerciales.[^gptk-license] ForgePlay se publica actualmente sin precio de compra, y su acceso no está condicionado a un pago ni a un patrocinio. Tampoco presenta GPTK o D3DMetal como componentes de código abierto propiedad de ForgePlay; siguen siendo componentes independientes de terceros sujetos a la licencia que los acompaña.

CodeWeavers declara públicamente que CrossOver 26 incluye D3DMetal 3.0, y CrossOver se vende como producto de pago.[^crossover26]

Esto deja una pregunta directa para CodeWeavers:

> **¿Dispone CodeWeavers de un acuerdo comercial independiente o una autorización de redistribución que permita incluir D3DMetal en versiones de pago de CrossOver y distribuirlo a los usuarios finales?**

Nadie está pidiendo precios confidenciales ni el contrato íntegro. Si esa autorización existe, CodeWeavers puede confirmar su existencia e identificar los productos y versiones a los que se aplica.

No hay motivo para mantener públicamente incierta la base de redistribución comercial de un componente importante de terceros dentro de un producto de pago. Si CodeWeavers se presenta como defensor del código abierto y de la libertad del software, debería ofrecer al menos una transparencia mínima sobre la autoridad comercial en la que se basa su propia distribución.

ForgePlay se aplica el mismo criterio. Si cambia su modelo de distribución o de ingresos, volverá a revisar las licencias de las versiones de GPTK y D3DMetal que utilice. ForgePlay no presumirá derechos que la licencia aplicable no conceda.

### Por qué ForgePlay es código abierto

ForgePlay es código abierto porque las críticas deben poder comprobarse.

Si afirmo que CrossOver se acomodó por falta de competencia seria, primero debo demostrar que otra arquitectura puede funcionar de verdad.

- La arquitectura del Game Host debe poder inspeccionarse.
- El proceso en el que se activa el modo Juego debe poder revisarse.
- Los prefijos y ajustes de cada juego deben ser visibles.
- Las afirmaciones sobre rendimiento y compatibilidad deben poder verificarse mediante el código y los registros.
- Los fallos y las limitaciones no deben ocultarse.

El proyecto oficial ForgePlay sigue dirigido por su mantenedor y actualmente no acepta contribuciones de código. Dentro de lo permitido por las licencias aplicables, cualquiera puede inspeccionar el código fuente, crear una bifurcación o desarrollar una implementación independiente.

CrossOver eligió un producto comercial que incluye componentes propietarios. ForgePlay elige publicar su propio código, exponer la arquitectura y el resultado, y permitir que los usuarios los comparen directamente.

ForgePlay tampoco queda exento de este criterio. Para cada modificación de Wine, debe indicar qué cambios llegaron upstream y cuáles siguen siendo específicos de ForgePlay, y debe publicar los motivos, el conjunto completo de parches y los materiales de compilación de todo aquello que permanezca downstream. **No utilizará «la mayor parte es abierta» para ocultar las excepciones que importan.**

### Si no existe un competidor, créalo

Abandoné una carrera descrita como un cuenco de arroz de hierro porque ya había visto cómo se endurece una organización cuando los problemas sin resolver no suponen ningún coste para su supervivencia.

No quería aceptar como inevitable la misma complacencia en el software.

La contribución de CodeWeavers a Wine merece respeto. Eso no convierte la arquitectura actual de CrossOver en la respuesta definitiva para el ecosistema. Toda organización o producto que permanezca demasiado tiempo como referencia sin una competencia significativa acabará endureciéndose.

La cifra del 95 % de CodeWeavers demuestra una contribución. También demuestra un límite: el 5 % restante queda fuera del upstream compartido. Cuando esa distancia se combina con datos privados de compatibilidad, componentes propietarios y una autorización comercial opaca para D3DMetal, un núcleo de código abierto puede pasar de ser una base común a convertirse en un foso comercial controlado por una sola empresa.

La implementación del Game Host y del modo Juego es un ejemplo concreto. Un desarrollador independiente identificó e implementó una arquitectura que CodeWeavers nunca convirtió en una función del producto. No era técnicamente imposible. Simplemente no tuvo que priorizarse mientras no existiera un competidor equivalente.

La dependencia de soluciones comunitarias, la concentración del conocimiento práctico en datos privados y la falta de claridad sobre los derechos de redistribución comercial reflejan el mismo problema subyacente. Cuando la competencia es débil, también lo es la presión para explicar y mejorar.

Esa insatisfacción es una de las principales razones por las que existe ForgePlay.

> **Si el líder establecido no lo pensó porque no tenía competencia, lo pensaré yo.**  
> **Si el líder establecido no lo construyó porque no tenía competencia, lo construiré yo.**

ForgePlay no es un eslogan contra CrossOver. Es la implementación de decisiones que CrossOver no tomó, publicada para que el resultado pueda ponerse a prueba en público.

> **Si la falta de competencia detuvo el progreso, la respuesta es crear competencia.**

ForgePlay existe para iniciar esa competencia.

[^crossover-95]: CodeWeavers, [CrossOver](https://www.codeweavers.com/crossover), [Código abierto](https://www.codeweavers.com/open-source) y [Código fuente de CrossOver](https://www.codeweavers.com/crossover/source). CodeWeavers afirma que el 95 % del código base de Wine que desarrolla para CrossOver se devuelve al proyecto Wine; afirma por separado que el trabajo sobre Wine se envía primero upstream y proporciona archivos FOSS de fuentes específicos para cada versión.
[^lgpl]: Proyecto GNU, [Licencia Pública General Reducida de GNU, versión 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html), especialmente las secciones 2, 4 y 6. La licencia exige el código fuente correspondiente para el código de biblioteca modificado que se distribuye, pero no exige su aceptación ni integración en un repositorio upstream concreto.
[^game-mode]: Apple, [Usar el modo Juego en el Mac](https://support.apple.com/en-us/105118) y [`LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode).
[^crossover-settings]: CodeWeavers, [Ajustes avanzados en CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^compatibility-database]: CodeWeavers, [La base de datos de compatibilidad](https://support.codeweavers.com/en_US/the-compatibility-database) y [aviso sobre los consejos de CrossOver](https://www.codeweavers.com/compatibility/crossover/tips/codeweavers-crossover/bottles-and-installing).
[^crossover-proprietary]: CodeWeavers, [Código abierto](https://www.codeweavers.com/open-source) y [Ajustes avanzados en CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^gptk-license]: El archivo `License.rtf` incluido con la distribución oficial de Game Porting Toolkit que acompaña a ForgePlay, secciones 1, 2.A y 2.C.
[^crossover26]: CodeWeavers, [anuncio de CrossOver 26](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac).
