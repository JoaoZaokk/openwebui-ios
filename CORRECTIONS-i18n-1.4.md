# Correções i18n 1.4 — APLICADAS ✅ (revisão adversarial das 9 línguas novas)

> **Status: tudo aplicado no commit `8ca65f1`** (63 edits, 8 arquivos). Só o item 49 (P2,
> cosmético) ficou de fora, por escolha. Duas melhorias sobre o proposto aqui: em `he` item 44
> usou-se `לפעול מעצמה` (o `להופעל` sugerido é huf'al sem infinitivo válido); em `bo` item 40
> `འདོར་བ།` também removeu colisão com "Desafixar". Documento mantido como registro.

Verificação feita em 2026-07-16 (3 agentes adversariais + checks determinísticos +
runtime no simulador). **Estrutural: tudo OK** — 44 .lproj × 176 chaves idênticas,
plutil-clean, `%@`/`\n` preservados, zero chars de controle bidi, zero mojibake,
scripts corretos (uigur árabe ئ/ۇ/ې, tibetano com tsheg, mongol cirílico ө/ү),
RTL verificado na tela (he, ug) e tibetano renderiza sem tofu (bo).

**Já corrigido (commit `664509d`):** bug de double-escape que quebrava o lookup de
2 chaves (`\n`/`\"`) nas 9 línguas novas — caíam em português. NÃO reintroduzir:
ao regravar `.strings`, nunca re-escapar o texto das chaves de `keys.json`.

Abaixo: correções de TRADUÇÃO pendentes, por prioridade. Formato:
`"chave pt-BR"` → valor atual ⇒ **valor corrigido**.

---

## P0 — Sentido invertido/errado na UI

### he (hebraico)
1. `"Texto → Voz"` → `טקסט → קול` ⇒ **`טקסט ← קול`**
   (U+2192 não espelha em RTL; na tela a seta aponta pro lado errado e a linha lê "Voz→Texto")
2. `"Voz → Texto"` → `קול → טקסט` ⇒ **`קול ← טקסט`** (mesmo bug; as linhas TTS/STT parecem trocadas)

### fi (finlandês)
3. `"Base de Conhecimento"` → `Tietokanta` (= *banco de dados*) ⇒ **`Tietämyskanta`**
4. `"Anexar Base de Conhecimento"` → ⇒ **`Liitä tietämyskanta`**
5. `"Nenhuma base de conhecimento."` → ⇒ **`Ei tietämyskantoja.`**
6. `"Carregar Arquivos"` → `Lataa tiedostoja` (colide com "Baixar"=Lataa; upload≠download) ⇒ **`Lähetä tiedostoja`**

### mn (mongol)
7. `"Nativo iOS"` e demais `Nativo…` (4 ocorrências) → `Нативо` (português transliterado!) ⇒ **`Төрөлх iOS`** / **`Төрөлх`**
8. `"Sessão expirada. Faça login novamente."` → `Сесс…` (russo truncado) ⇒ **`Холболтын хугацаа дууссан. Дахин нэвтэрнэ үү.`**
9. `"Enquanto a IA fala…"` → `тан руу сонсоно` ⇒ trecho **`таныг сонсоно`** ("te ouve", caso correto)
10. `"Resposta inesperada do servidor: %@"` → `санамсаргүй хариу` ("resposta descuidada") ⇒ **`гэнэтийн хариу`**

### bo (tibetano)
11. `"Enquanto a IA fala…"` → `བརྙན་ཤུགས` ("força-imagem" ≠ eco) ⇒ **`བྲག་ཅ`**
12. `"Excluir"` → `སུབ་འདོན` (grafia inválida) ⇒ **`རྩ་བསུབ།`** (mantém distinto de "Apagar"=`བསུབ`)
13. `"Editar nota"` → `ཞུ་དག` (= revisar/corrigir texto) ⇒ **`ཟིན་བྲིས་རྩོམ་སྒྲིག`**

### ug (uigur)
14. `"PROMPT"` / `"Assistente de prompt (IA)"` → `سۆزلەم` (= "frase") ⇒ **`كۆرسەتمە`** (ou empréstimo `پرومپت`)
15. `"Sessão expirada…"` → `ئولتۇرۇش` (= "reunião/sentar") ⇒ **`كىرىش ۋاقتى ئۆتتى. قايتا كىرىڭ.`**

---

## P1 — Gramática/idiomaticidade

### lb (luxemburguês) — germanismos e declinação
16. `"Este modelo não tem visão…"` → `Dëst Modell` ⇒ **`Dëse Modell`** (Modell é masculino em lb)
17. `"Falha ao descompactar o modelo Core ML."` → `d'Core ML Modell` ⇒ **`de Core ML Modell`**
18. `"Modelo ativo"` → `Aktiivt Modell` ⇒ **`Aktive Modell`**
19. `"Ex.: http://…"` → `net aginn` ⇒ **`net agitt`** (2ª pessoa plural)
20. `"Enquanto a IA fala…"` → `vun eleng ausléisen` ⇒ **`vu sech eleng ausléisen`**
21. `"Descreva sua ideia…"` → `a einfache Wierder` ⇒ **`an einfache Wierder`** (regra do -n antes de vogal)
22. `"Brasas"` → `Glout` (germanismo) ⇒ **`Glous`**
23. `"Microfone indisponível."` + 4 strings com `verfügbar` (alemão) ⇒ usar **`disponibel`** (ex.: `Mikro net disponibel.`)
24. `"Expandir / jogar pro canto"` → `an d'Eck` ⇒ **`an den Eck`** (Eck masculino em lb)
25. `"A página é lida no servidor…"` → `ugehaang.` ⇒ **`ugehaangen.`**
26. `"Capturar"` → `Erfaassen` (captura de dados) ⇒ **`Ophuelen`** (câmera)

### fi
27. `"Descreva a imagem…"` → `Kuvaile kuva…` ⇒ **`Kuvaile kuvaa…`** (partitivo)
28. `"Descreva sua ideia em palavras simples…"` → `Kuvaile ideasi` ⇒ **`Kuvaile ideaasi`**
29. `"Passos"` → `Askeleet` (passos de caminhada) ⇒ **`Vaiheet`** (steps de geração)

### mn
30. `"Assistente de prompt (IA)"` + 3 strings com `ИИ` (abreviação russa) ⇒ manter **`AI`**
31. `"Tema"`/`"Temas"` → `Тема`/`Темүүд` (russo) ⇒ **`Сэдэв`** / **`Сэдвүүд`**
32. `"Renomear conversa"` → `Яриаг нэр солих` ⇒ **`Ярианы нэрийг солих`**
33. `"Conversas"` → `Яриа` (igual ao singular; tab e chat leem igual) ⇒ **`Ярианууд`**
34. `"Brasas"` → `Оч` (faísca) ⇒ **`Цог`**
35. `"Falha ao iniciar o stream"` → `Стрим` ⇒ **`урсгал`** (ex.: `Урсгалыг эхлүүлж чадсангүй`)

### bo
36. `"Capturar"` → `འཇུ་ལེན` (cunhagem dúbia) ⇒ **`པར་ལེན།`**
37. `"Passos"` → `གོམ་གྲངས` (contagem de passos) ⇒ **`རིམ་པ།`**
38. `"Brasas"` → `མེ་ཐལ` (cinzas) ⇒ **`མེ་མདག`**
39. `"Nativo iOS"` + variantes → `རང་ཇུས` (termo inventado) ⇒ **`iOS ངོ་མ`** (aplicar consistente nas 4 ocorrências)
40. `"Cancelar"` → `ཕྱིར་འཐེན` (retirar) ⇒ **`འདོར་བ`**

### ug
41. `"Sintetizando…"` → `ھاسىللاۋاتىدۇ` (forma verbal inválida) ⇒ **`ئاۋاز ھاسىل قىلىنىۋاتىدۇ…`**
42. `"Passos"` → `قەدەملەر` (passos de andar) ⇒ **`باسقۇچلار`**
43. `"Fixar"`/`"Desafixar"` → `قىستۇرۇش` (= inserir) ⇒ **`چوققىغا بېكىتىش`** / **`بېكىتىشنى ئېلىۋېتىش`**

### he
44. `"Enquanto a IA fala…"` → `אך עלולה להיקטע לבד מההד` ("pode se cortar sozinha") ⇒ **`אך עלולה להופעל מעצמה בגלל ההד`** ("pode disparar sozinha com o eco")
45. `"Baixar"` → `הורדה` (substantivo; inconsistente com `הורד` vizinho) ⇒ **`הורד`**

### sv
46. `"Falha ao iniciar o stream"` → `starta strömmen` (lê "ligar a corrente elétrica") ⇒ **`Det gick inte att starta strömningen`**

### lv
47. `"Sair"` → `Iziet` ⇒ **`Izrakstīties`** (logout na seção CONTA, par de `Pieteikties`)
48. `"Enquanto a IA fala…"` → `var nostrādāt pati no atbalss` ⇒ **`var nostrādāt pati no sevis atbalss dēļ`**

---

## P2 — Cosmético ✅ FEITO
49. ~~Exemplo `meu-servidor.com` em português.~~ **Resolvido nas 44 línguas** (commit abaixo).
    O escopo real era maior que "as 9": 10 línguas mostravam o domínio português (incl. ko,
    zh-Hans, zh-Hant) e 12 caíam no inglês. Agora cada uma tem forma local em ASCII
    (romanização p/ cirílico e RTL; pinyin p/ zh-Hans); ja/ko/zh-Hant/th/hi/bn/bo mantêm
    `my-server.com` de propósito — nesses ecossistemas placeholder é inglês.

## Línguas limpas
- **th (tailandês): zero achados.**
- **lv: quase limpa** (só 47–48).

## Como aplicar (regras)
- Editar SOMENTE o valor (lado direito) em `App/Resources/<code>.lproj/Localizable.strings`; a chave pt-BR fica intocada.
- Não tocar em `%@`, `\n`, `\"` — contagem/posição têm que continuar batendo.
- Depois: `plutil -lint` em cada arquivo editado + build do scheme OpenWebUI + commit.
- Sanity final: rodar o check de consistência (chaves/placeholders vs pt-BR) nas 44 línguas.
