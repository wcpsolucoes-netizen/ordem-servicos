# Ordem — ordens de serviço da equipe

Aplicação web responsiva e instalável como atalho (PWA). O GitHub Pages hospeda os arquivos estáticos; o Supabase armazena as O.S., autentica os membros e envia notificações push.

## Demonstração local

Abra `index.html` em um servidor local ou publique no Pages. Sem configuração do Supabase, o site entra em modo de demonstração e mantém os PINs e as O.S. somente no armazenamento daquele navegador. **Não use esse modo para compartilhar dados reais.**

## Configuração online

1. Crie um projeto Supabase no plano gratuito. O plano tem limites e pode pausar projetos inativos; confira as condições atuais do serviço.
2. Em **Authentication → Sign-in / Providers**, desative o cadastro público de novos usuários. A aplicação cria as contas pelo código individual; permitir cadastros públicos pode deixar alguém reservar um perfil antes do membro legítimo.
3. No **SQL Editor** do Supabase, execute `supabase/schema.sql`.
4. Crie um código de ativação forte e exclusivo para cada pessoa (pelo menos 8 caracteres aleatórios). No SQL Editor, cadastre cada código para o perfil correspondente, sem o incluir no repositório:

   ```sql
   select public.set_invite_code('theo', 'CODIGO_ALEATORIO_EXCLUSIVO');
   ```

   Repita para `wainy`, `jenifer`, `rayan`, `cristiano`, `otavio` e `pedro`, e entregue cada código somente ao respectivo membro. O código é de uso único; no primeiro acesso, a pessoa escolhe seu nome, informa o código e define o PIN de 4 dígitos.
5. Instale e autentique a Supabase CLI, vincule o projeto e faça deploy das funções:

   ```sh
   supabase login
   supabase link --project-ref SEU_PROJECT_REF
   supabase functions deploy setup-member
   supabase functions deploy send-reminders
   ```

   Configure os secrets das funções no painel Supabase:
   - `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` (o Supabase costuma disponibilizá-los no ambiente das funções; **nunca** publique a service-role key).
   - `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` e `VAPID_SUBJECT`.
   - `APP_URL`, com a URL publicada no GitHub Pages, incluindo o caminho do repositório se aplicável.
6. Gere as chaves VAPID com `npx web-push generate-vapid-keys`. Guarde a chave privada apenas nos secrets do Supabase. Coloque a chave pública em `VAPID_PUBLIC_KEY` no `config.js`.
7. Copie a **Project URL** e a chave **anon/public** do Supabase para `SUPABASE_URL` e `SUPABASE_ANON_KEY` no `config.js`. A chave anon é pública e protegida pelas políticas RLS; não coloque a service-role key nesse arquivo.
8. Ative **pg_cron**, **pg_net** e **Vault** no Supabase e agende `send-reminders` para executar a cada minuto. Cadastre a URL do projeto e a service-role key como secrets do Vault e use-as na chamada HTTP:

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
           'Authorization', 'Bearer ' ||
             (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
         ),
         body := '{}'::jsonb
       );
     $$
   );
   ```

   Crie os secrets `supabase_url` e `service_role_key` no Vault antes de agendar, usando **Database → Vault → Secrets → Add new secret**. Guarde a URL do projeto como `supabase_url` e a service-role key como `service_role_key`; não coloque valores secretos no código versionado.
9. No GitHub, habilite **Settings → Pages** para publicar a pasta raiz da branch escolhida. O Pages fornece HTTPS, necessário para instalação da PWA e notificações.

As notificações push são enviadas cerca de 10 minutos antes, considerando o fuso `America/Sao_Paulo`: segunda a sexta, das 8h às 18h; sábado, das 9h às 12h; nunca aos domingos. A janela de envio é verificada no servidor, não só no celular. O painel atualiza as O.S. compartilhadas a cada 30 segundos. O membro também precisa permitir notificações no navegador. No iPhone/iPad, instale pelo menu **Compartilhar → Adicionar à Tela de Início** e permita os avisos; o suporte a push depende da versão do iOS/iPadOS.

## Papéis

- **Wainy e Jênifer:** administradoras; criam O.S., escolhem técnicos e anexam arquivos, mas não iniciam nem finalizam O.S.
- **Rayan e Cristiano:** administradores e técnicos; podem criar, executar, anexar, finalizar O.S. atribuídas a eles e cancelar O.S.
- **Theo, Otavio e Pedro:** técnicos; executam e finalizam O.S. atribuídas a eles, anexam arquivos e podem cancelar O.S.

Os arquivos anexados têm limite de 8 MB e ficam no bucket privado do Supabase Storage. Todos os membros autenticados podem consultar as O.S. da equipe.

Administradores também podem editar os dados de qualquer O.S. sem alterar o status; as mudanças ficam registradas no histórico da ordem. O histórico inclui criação, edição, anexos e mudanças de status. A tela da O.S. mostra o agendamento, o início da execução, a conclusão e o tempo transcorrido; ao finalizar, o tempo é congelado como a duração total entre início e fim. Ordens iniciadas antes desta atualização não têm um horário de início retroativo, então a duração só será calculada para execuções iniciadas depois da migração. Os lembretes agendados são enviados ao técnico responsável e a todos os administradores que ativarem notificações.

### Atualização do banco para auditoria e duração

Se o schema original já foi aplicado, execute uma única vez o script `supabase/migrations/20260610_admin_auditoria_etapas.sql` no SQL Editor do Supabase. Ele é uma migração incremental e não apaga as ordens existentes. Não é necessário executar novamente o schema inteiro.
