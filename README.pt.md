# claude-life-os

[English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Polski](README.pl.md) · [Français](README.fr.md) · [Español](README.es.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Русский](README.ru.md) · **Português**

Um sistema pessoal para a papelada. Lê o teu Gmail e o teu Google Drive, mantém um índice
de cada documento oficial, carta, contrato e fatura numa base de dados que é tua, e
garante que nenhum prazo, renovação automática ou fim de validade te escapa. Fazes
perguntas em linguagem normal, em qualquer conversa do Claude: «quando expira o meu
passaporte», «ainda posso cancelar o ginásio», «o que diz o contrato de arrendamento
sobre animais».

Foi construído por uma pessoa para a sua própria vida, usado todos os dias durante um
mês, e está agora a tornar-se algo que qualquer pessoa pode instalar. Não é preciso
programar: o Claude guia-te em cada passo.

## Instalação

Isto é para o Claude normal: claude.ai no navegador, ou a app Claude no computador ou no
telemóvel. Não para o Claude Code.

**1. Descarrega a skill: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (não a descompactes). É uma única skill
que contém tudo: instalação, correio, ficheiros, verificação noturna, revisão mensal e as
respostas às tuas perguntas. A ligação aponta sempre para a versão mais recente
([todas as versões](https://github.com/denysovkos/claude-life-os/releases)).

**2. Adiciona-a ao Claude.** No Claude abre **Settings** → **Capabilities**, ativa
**Code execution and file creation** (as skills precisam disso) e depois, em **Skills**,
clica em **Upload skill** e escolhe `life-os.zip`.

**3. Liga as tuas contas.** **Settings** → **Connectors**: Google Drive, Gmail e Supabase;
se quiseres também Google Calendar, Todoist, Craft.

**4. Abre uma conversa nova e escreve: `set up life os`.** A partir daqui guia o Claude.
Faz algumas perguntas (a tua língua, o teu país, que apps usas), cria a base de dados e
as pastas no Drive, e verifica cada passo antes do seguinte.

**5. Instala a ponte Google Apps Script** quando o Claude pedir. É um ficheiro que corre
na tua conta Google a cada 15 minutos, mesmo quando o Claude não está a funcionar (nomes
dos botões em inglês; o Google pode mostrá-los em português):

- script.google.com → **New project** → cola o código que o Claude te mostra → guarda;
- **Project Settings** → **Script Properties** → adiciona `SUPABASE_URL` e
  `SUPABASE_SECRET_KEY` (o Claude diz onde os encontrar; a chave vai só para ali, nunca
  para uma conversa);
- escolhe a função `install` → **Run** → **Review permissions** → a tua conta → «Google
  hasn't verified this app» → **Advanced** → **Go to Life OS bridge (unsafe)** →
  **Select all** → **Allow**. O aviso é normal: é o teu próprio script e só corre na tua
  conta.

Passo a passo, com a explicação de cada permissão (em inglês):
[docs/apps-script.md](docs/apps-script.md).

**6. Deixa-a correr todas as noites.** O Claude não arranca sozinho, por isso cria quatro
execuções agendadas, de preferência à noite e por esta ordem: correio às **01:05**,
ficheiros às **02:05**, a verificação noturna com o teu resumo diário às **03:05** e a
revisão mensal no dia 1 às **04:05**. O correio primeiro, porque a sua classificação diz à
ponte que anexos copiar; os ficheiros uma hora depois indexam-nos na mesma noite; a
verificação no fim, para que o resumo da manhã inclua tudo. O mais simples são as routines
do Claude Code, que correm na nuvem mesmo com o computador desligado:
[docs/scheduling.md](docs/scheduling.md) (em inglês) explica cada clique e os comandos
`/schedule`.

É tudo, cerca de 30 minutos. Mais tarde, a qualquer momento, escreve
**`life os doctor`**: verifica todo o sistema e diz-te exatamente o que corrigir.

**Atualizar:** descarrega o novo `life-os.zip` e carrega-o da mesma forma (se o Claude não
substituir a skill, apaga primeiro a antiga). Depois escreve `life os doctor`: aplica ele
próprio as atualizações da base de dados e as novas regras.


### O que precisas

- Uma conta Google (Gmail e Google Drive).
- Um plano Claude com skills e conectores.
- Uma conta gratuita [Supabase](https://supabase.com). O Supabase é a base de dados onde
  vive o índice; o plano gratuito chega. O Claude cria o projeto por ti.
- Opcional: Todoist para tarefas, Craft para o relatório mensal. Sem eles, tarefas e
  relatórios chegam por e-mail e como Google Docs.

## O que faz por ti

- **Todas as noites** lê o correio novo, divide-o em 10 categorias (faturas, serviços
  públicos, banco, contratos, viagens, etc.), extrai valores e datas de pagamento, e cria
  uma tarefa quando tens de agir. Viagens e consultas tornam-se eventos no calendário.
- **Os anexos importantes** (faturas, contratos, cartas de entidades públicas) são
  copiados automaticamente para o Google Drive, arquivados na pasta certa e indexados com
  o texto completo.
- **Acompanha prazos, não só datas.** Uma autorização de residência que expira; uma
  decisão de que se pode reclamar dentro de um mês; um seguro que se renova sozinho se
  não o cancelares três meses antes: cada um torna-se um prazo com lembretes cada vez mais
  frequentes. A forma de contar um prazo depende do teu país.
- **Um breve resumo diário**, só nos dias em que algo importa. Nunca um «está tudo bem».
- **Uma revisão mensal**: quanto pagas por mês, o que mudou, o que podes cancelar e até
  quando, o que vai para a declaração de impostos e o que parece estranho.
- **Uma pasta de emergência**: um Google Doc reescrito todos os dias com os assuntos em
  aberto, prazos, contratos, seguros, onde estão os originais e a quem ligar.

## Tarefas no teu gestor de tarefas

A base de dados mantém a lista; o gestor de tarefas apenas a espelha, por isso nada se
perde se mudares de app ou não usares nenhuma. Com o Todoist recebes:

| Tarefa | Quando |
|---|---|
| `📅 Daily brief <data>: <o mais importante>` | só nos dias em que algo importa; o resumo está na descrição |
| `💌 <categoria> <remetente>: <o que fazer>` | uma carta exige uma ação |
| `⚠️ <documento> expires <data>: <ficheiro>` | um documento expira dentro de 30 dias |
| `🧾 Review <mês>: <decisão principal>` | uma vez por mês, as decisões que só tu podes tomar |
| `⚠️ <tarefa> failed <data>` | uma execução noturna teve erros |

Os títulos ficam na língua que escolheres; as palavras `Daily brief` ficam em inglês
porque é por elas que o sistema reconhece o próprio resumo. Concluir uma tarefa fecha o
prazo que está por trás. Mais em [docs/tasks.md](docs/tasks.md) (em inglês).

## Definições

Todas as definições estão numa tabela da tua própria base de dados, `life_settings`, e
cada alteração fica registada em `settings_history`, visível e reversível. Para mudar
alguma coisa, basta dizê-lo: «muda a língua para inglês», «mudei-me para a Alemanha»,
«adiciona a minha irmã à pasta de emergência». Quando o teu país ou as suas regras mudam,
os prazos já calculados são recalculados, depois de o Claude te mostrar o que se move.
Detalhes em [docs/settings.md](docs/settings.md) (em inglês).

## Línguas e países

O sistema lê correio em qualquer língua. Os seus próprios textos (resumos, tarefas,
relatórios, pasta de emergência, nomes de pastas) existem nestas línguas:

| Língua | Estado |
|---|---|
| English, Deutsch, Українська | completas e testadas |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | tradução inicial, inglês onde falta |

As regras legais (como se conta um prazo de reclamação, quando se pode cancelar um
contrato de telemóvel, até quando devolver uma compra, quando entregar a declaração) vêm
num **pacote regional**. A **Alemanha** está completa. Nos outros países o sistema
continua a acompanhar cada data que lê, mas usa valores prudentes e pergunta-te pelas
regras locais. Para adicionar uma língua ou um país: [packs/README.md](packs/README.md).

## Privacidade e segurança

Os teus dados ficam nas tuas contas: o teu Gmail, o teu Drive, o teu projeto Supabase.
Não há nenhum servidor pelo meio e mais ninguém tem acesso. A base de dados está fechada
de forma que a sua interface pública não devolve nada; só o Claude (através do teu
conector) e o teu próprio Apps Script a podem ler. Os ficheiros nunca passam pela IA: o
Google move-os diretamente do Gmail para o Drive. Detalhes em
[docs/security.md](docs/security.md) (em inglês).

## Como funciona

Tudo o que tem de acontecer a horas é feito por coisas que não se esquecem: Google Apps
Script a cada 15 minutos e tarefas agendadas dentro da base de dados todas as noites. O
Claude faz só o que exige juízo: ler uma carta e perceber o que significa. A base de
dados é a única fonte de verdade; Todoist, Craft e o calendário apenas a espelham.

- [docs/architecture.md](docs/architecture.md): componentes, modelo de dados, o percurso de uma carta.
- [docs/apps-script.md](docs/apps-script.md): instalar a ponte.
- [docs/scheduling.md](docs/scheduling.md): o horário noturno: routines, horas, ordem.
- [docs/tasks.md](docs/tasks.md): o que chega ao gestor de tarefas e como se fecha.
- [docs/settings.md](docs/settings.md): todas as definições e o que acontece quando uma muda.
- [docs/security.md](docs/security.md): chaves, permissões, o que a IA vê, cópias de segurança.
- [docs/troubleshooting.md](docs/troubleshooting.md): cada falha do original e como se resolve.

## Estado

Inicial. A base de dados, a ponte e o processamento de correio correram todos os dias
durante um mês na versão privada original e depois foram generalizados. A skill de
instalação e os pacotes são novos. Conta com arestas por limar e reporta-as, por favor.
