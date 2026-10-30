# Ordem — ordens de serviço da equipe

Aplicação web responsiva e instalável como atalho (PWA). O GitHub Pages hospeda os arquivos estáticos; o Supabase armazena as O.S., autentica os membros e envia notificações push.

## Demonstração local

Abra `index.html` em um servidor local ou publique no Pages. Sem configuração do Supabase, o site entra em modo de demonstração e mantém os PINs e as O.S. somente no armazenamento daquele navegador. **Não use esse modo para compartilhar dados reais.**

## Configuração online

1. Crie um projeto Supabase no plano gratuito. O plano tem limites e pode pausar projetos inativos; confira as condições atuais do serviço.
2. Em **Authentication → Sign-in / Providers**, desative o cadastro público de novos usuários. A aplicação cria as contas pelo código individual; permitir cadastros públicos pode deixar alguém reservar um perfil antes do membro legítimo.
3. No **SQL Editor** do Supabase, execute `supabase/schema.sql`.
4. Se o banco já estava em uso, não execute novamente o schema inteiro: aplique apenas as migrações incrementais pendentes, na ordem indicada ao final deste README. Para um projeto novo, execute `schema.sql` e depois as migrações, na ordem indicada.
5. Crie um código de ativação forte e exclusivo para cada pessoa (pelo menos 8 caracteres aleatórios). No SQL Editor, cadastre cada código para o perfil correspondente, sem o incluir no repositório:

   ```sql
   select public.set_invite_code('theo', 'CODIGO_ALEATORIO_EXCLUSIVO');
   ```

   Repita para `wainy`, `jenifer`, `rayan`, `cristiano`, `otavio` e `pedro`, e entregue cada código somente ao respectivo membro. O código é de uso único; no primeiro acesso, a pessoa escolhe seu nome, informa o código e define o PIN de 4 dígitos.
6. Instale e autentique a Supabase CLI, vincule o projeto e faça deploy das funções:

   ```sh
   supabase login
   supabase link --project-ref SEU_PROJECT_REF
   supabase functions deploy setup-member
   supabase functions deploy send-reminders --no-verify-jwt
   ```

   Configure os secrets da função `send-reminders` no painel Supabase:
   - `VAPID_PUBLIC_KEY` (a mesma chave pública definida em `config.js`), `VAPID_PRIVATE_KEY` e `VAPID_SUBJECT` (por exemplo, `mailto:seu-email@dominio.com`).
   - `CRON_SECRET`, um valor aleatório forte e exclusivo. Cadastre o mesmo valor também no Vault, com o nome `cron_secret`.
   - `APP_URL`, com a URL HTTPS publicada no GitHub Pages, incluindo o caminho do repositório se aplicável.
   - `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` normalmente já são disponibilizados pelo Supabase no ambiente das funções. Nunca publique nem coloque a service-role key no código do site.
7. Gere as chaves VAPID com `npx web-push generate-vapid-keys`. Guarde a chave privada apenas nos secrets do Supabase. Coloque a chave pública em `VAPID_PUBLIC_KEY` no `config.js`.
8. Copie a **Project URL** e a chave **anon/public** do Supabase para `SUPABASE_URL` e `SUPABASE_ANON_KEY` no `config.js`. A chave anon é pública e protegida pelas políticas RLS; não coloque a service-role key nesse arquivo.
9. Ative **pg_cron**, **pg_net** e **Vault** no Supabase e agende `send-reminders` para executar a cada minuto. Cadastre a URL do projeto e o mesmo segredo de cron configurado na função como secrets do Vault e use-os na chamada HTTP:

   ```sql
   create extension if not exists pg_cron;
   create extension if not exists pg_net with schema extensions;
   create extension if not exists supabase_vault with schema vault;

   select cron.schedule(
     'send-os-reminders',
     '* * * * *',
     $$
       select net.http_post(
         url := (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_url')
           || '/functions/v1/send-reminders',
         headers := jsonb_build_object(
           'Content-Type', 'application/json',
           'x-cron-secret',
             (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
         ),
         body := '{}'::jsonb
       );
     $$
   );
   ```

   Crie os secrets `supabase_url` e `cron_secret` no Vault antes de agendar, usando **Database → Vault → Secrets → Add new secret**. O valor de `cron_secret` deve permanecer secreto e não deve ser incluído no código versionado. A função valida esse segredo no cabeçalho `x-cron-secret`; por isso, desative **Verify JWT with legacy secret** nas configurações da função `send-reminders` (o deploy acima já desativa a verificação JWT pela CLI).
10. No GitHub, habilite **Settings → Pages** para publicar a pasta raiz da branch escolhida. O Pages fornece HTTPS, necessário para instalação da PWA e notificações.

Com o site aberto, o app verifica os agendamentos e exibe um aviso quando faltam até 10 minutos; para receber pop-up do sistema, permita notificações no navegador. Para receber avisos com o site fechado, também é necessário publicar a função `send-reminders`, configurar os secrets VAPID e manter o cron do Supabase agendado por minuto conforme os passos acima. A permissão no navegador, sozinha, não ativa o envio pelo servidor. A janela do push considera o fuso `America/Sao_Paulo`: segunda a sexta, das 8h às 18h; sábado, das 9h às 12h; nunca aos domingos. O painel atualiza as O.S. compartilhadas a cada 30 segundos. No iPhone/iPad, instale pelo menu **Compartilhar → Adicionar à Tela de Início** e permita os avisos; o suporte a push depende da versão do iOS/iPadOS.

## Papéis

- **Wainy e Jênifer:** administradoras; criam O.S., escolhem técnicos e anexam arquivos, mas não iniciam nem finalizam O.S.
- **Rayan e Cristiano:** administradores e técnicos; podem criar, executar, anexar, finalizar O.S. atribuídas a eles e cancelar O.S.
- **Theo, Otavio e Pedro:** técnicos; executam e finalizam O.S. atribuídas a eles, anexam arquivos e podem cancelar O.S.

Os arquivos anexados têm limite de 8 MB e ficam no bucket privado do Supabase Storage. Imagens e PDFs abrem em uma prévia dentro do app; imagens HEIC/HEIF usam conversão no navegador para visualização. Técnicos consultam apenas as O.S. atribuídas a eles; administradores têm visão geral da equipe.

Administradores podem excluir permanentemente qualquer O.S.; a exclusão também remove anexos e histórico e pede confirmação. A migração `20261102_admin_delete_work_orders.sql` instala a permissão administrativa no banco. A conclusão e a conciliação de entregas são apresentadas em um resumo próprio no cartão da O.S.; o histórico administrativo aparece em uma linha do tempo.

Administradores também podem editar os dados de qualquer O.S. sem alterar o status; as mudanças ficam registradas no histórico da ordem. O histórico inclui criação, edição, anexos e mudanças de status. A tela da O.S. mostra o agendamento, o início da execução, a conclusão e o tempo transcorrido; ao finalizar, o tempo é congelado como a duração total entre início e fim. Ordens iniciadas antes desta atualização não têm um horário de início retroativo, então a duração só será calculada para execuções iniciadas depois da migração. Os lembretes agendados são enviados ao técnico responsável e a todos os administradores que ativarem notificações.

Ordens concluídas ficam guardadas em **Pesquisa e arquivo**, com busca por serviço, local, técnico ou número e filtro por classificação (entrega, manutenção, instalação, reparo, vistoria ou outros). Administradores podem reclassificar uma O.S. ao editá-la; alterações entram no histórico.

Administradores também têm um **Dashboard** com ordens agendadas, em execução, concluídas no dia e agendamentos atrasados. O ranking diário inclui os técnicos, ordenados pelo número de O.S. concluídas no dia; em caso de empate, fica à frente quem tiver menor tempo médio registrado. A data diária considera o fuso de São Paulo.

Um técnico não consegue iniciar uma segunda O.S. enquanto tiver outra em execução. Ao finalizar, precisa registrar o que foi feito (mínimo de 3 caracteres) e pode anexar arquivos de até 8 MB no mesmo formulário. A validação acontece na interface e no banco; a O.S. não é concluída se a descrição for inválida ou se o envio de anexo falhar.

### Chamar técnico pelo WhatsApp

Administradores podem usar **Chamar técnico** em uma O.S. aberta para abrir a conversa do técnico responsável com uma mensagem automática já preenchida, identificando o administrador solicitante, o serviço e o horário agendado. O administrador ainda precisa revisar e tocar em **Enviar** no WhatsApp; o site não envia mensagens em segundo plano.

Para enviar pelo número comercial da Cristec, o navegador precisa estar conectado a esse WhatsApp pelo próprio WhatsApp Web. O QR code de **Aparelhos conectados** é gerado e validado pelo WhatsApp, não pelo site. Esta integração de clique para conversar não armazena a sessão do WhatsApp nem exige uma API de envio. Os números configurados no código do site ficam visíveis a quem puder acessar os arquivos públicos; antes de publicar, confirme que os titulares autorizam essa exposição.

### Atualização do banco para auditoria e duração

Se o schema original já foi aplicado, execute uma única vez `supabase/migrations/20260610_admin_auditoria_etapas.sql` no SQL Editor do Supabase. Ele é uma migração incremental e não apaga as ordens existentes. Não é necessário executar novamente o schema inteiro.

### Conciliação de entregas

Depois da migração de auditoria, execute uma única vez `supabase/migrations/20261030_conciliacao_entregas.sql`. Ela adiciona as classificações e a pesquisa/arquivo das O.S. concluídas, além do tipo de O.S. de entrega, valor a cobrar, forma de pagamento prevista, troco solicitado, fundo levado, maquininha e prestação de contas no retorno. Ao finalizar uma entrega, o técnico informa dinheiro/cartão/Pix recebidos, troco dado, dinheiro devolvido e devolução da maquininha. Diferenças na cobrança ou no caixa exigem uma observação e ficam registradas no histórico. O sistema registra valores para conferência; não processa pagamentos nem armazena dados de cartão.

### Acesso por membro e finalização

Depois da migração de conciliação, execute `supabase/migrations/20261030_member_visibility.sql` para restringir O.S. e anexos ao técnico responsável ou aos administradores. Em seguida, execute `supabase/migrations/20261101_execution_completion.sql`; ela bloqueia atomicamente uma segunda execução simultânea por técnico e exige uma descrição de conclusão com pelo menos 3 caracteres. Essa migração também atualiza a rotina de fechamento de entrega e adiciona o campo de descrição ao histórico. Para habilitar exclusão permanente de O.S. pelos administradores, aplique `supabase/migrations/20261102_admin_delete_work_orders.sql`.

Ordem completa para um banco novo: `schema.sql` → `20260610_admin_auditoria_etapas.sql` → `20261030_conciliacao_entregas.sql` → `20261030_member_visibility.sql` → `20261101_execution_completion.sql` → `20261102_admin_delete_work_orders.sql`. Em banco existente, aplique somente as migrações que ainda não foram executadas.
