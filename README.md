# Partiu

App de viagens (para iPhone, pela Tela de Início): passagens baratas saindo de São Paulo (Guarulhos, Congonhas ou Viracopos), hotel e Airbnb lado a lado, e os pontos turísticos de cada destino.

## Como funciona

- `app/destinos.json`: a lista de destinos (aeroportos, busca do Airbnb e os lugares para visitar). Para pôr um destino novo, é só acrescentar aqui.
- `coletar.rb`: robô que busca os preços. Passagens no Kayak (ida e volta, viagens de 3, 7 e 14 dias, ida em cada dia dos próximos meses), hotéis no Google Hotéis, casas no Airbnb e fotos/textos dos lugares na Wikipédia.
- `alertas.js`: manda notificação quando a passagem chega no preço pedido ou baixa 10%, e quando alguém do grupo manda uma viagem.
- `.github/workflows/atualizar.yml`: roda 3 vezes por dia (7h, 13h, 19h).
- `app/`: o app em si (publicado no GitHub Pages).
