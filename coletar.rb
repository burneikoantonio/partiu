# Robô do app de viagens: junta passagens saindo de São Paulo (GRU, CGH e VCP), hotéis, Airbnb e pontos turísticos.
#
#  - Passagens: Kayak "Explorar" (todos os destinos de uma vez para cada data de ida). Ida e volta, 1 adulto.
#    Viagens de 3, 7 e 14 dias, com ida em cada dia dos próximos meses -> calendário de preços por destino.
#  - Hotéis: Google Hotéis (preço por noite, nota, foto). Airbnb: página de busca (preço total da estadia).
#    Para não fazer milhares de buscas, hotel e Airbnb usam uma estadia de referência (3 noites, daqui a ~4 semanas).
#  - Lugares: Wikipédia (foto + resumo). Só busca o que ainda não tem.
#
# Uso: ruby coletar.rb            (tudo)
#      RAPIDO=1 ruby coletar.rb   (poucas datas, para testar)
#      SO=voos|hoteis|lugares     (só uma parte)
require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'base64'
require 'cgi'
require 'time'

Encoding.default_external = 'UTF-8'
Encoding.default_internal = 'UTF-8'
DIR = __dir__
DADOS = File.join(DIR, 'app/data')
require 'fileutils'
FileUtils.mkdir_p(DADOS)
Dir.mkdir(File.join(DADOS, 'voos')) unless Dir.exist?(File.join(DADOS, 'voos'))
CFG = JSON.parse(File.read(File.join(DIR, 'app/destinos.json'), encoding: 'UTF-8'))
DEST = CFG['destinos']
RAPIDO = ENV['RAPIDO'] == '1'
SO = ENV['SO'].to_s.strip.empty? ? nil : ENV['SO'].strip
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
HOJE = Date.today
AGORA = Time.now

def ler(arq, padrao)
  JSON.parse(File.read(arq, encoding: 'UTF-8'))
rescue StandardError
  padrao
end

def gravar(arq, x)
  File.write(arq, JSON.generate(x))
end

def baixar(url, tentativas: 3, cab: {})
  uri = URI(url)
  tentativas.times do |i|
    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 60
      req = Net::HTTP::Get.new(uri, { 'User-Agent' => UA, 'Accept-Language' => 'pt-BR,pt;q=0.9' }.merge(cab))
      res = http.request(req)
      return res.body.force_encoding('UTF-8') if res.code == '200'
      warn "  #{res.code} #{url[0, 110]}"
      return nil if %w[403 404].include?(res.code)
    rescue StandardError => e
      warn "  erro #{e.class} #{url[0, 90]}"
    end
    sleep(3 * (i + 1))
  end
  nil
end

# roda um bloco em paralelo (poucas conexões de cada vez, para não ser bloqueado)
def em_paralelo(itens, n)
  fila = Queue.new
  itens.each { |x| fila << x }
  Array.new(n) do
    Thread.new do
      loop do
        x = begin
          fila.pop(true)
        rescue ThreadError
          break
        end
        begin
          yield x
        rescue StandardError => e
          warn "  falhou: #{e.class} #{e.message[0, 120]}"
        end
      end
    end
  end.each(&:join)
end

# ---------------------------------------------------------------- passagens
def coletar_voos
  codigo_para = Hash.new { |h, k| h[k] = [] }
  DEST.each { |d| d['codigos'].each { |c| codigo_para[c] << d['id'] } }
  # viagens de 3 e 7 dias: ida em todos os dias; 14 dias: ida dia sim, dia não
  planos = { 3 => [1, 150], 7 => [1, 180], 14 => [2, 180] }
  planos = { 3 => [7, 30], 7 => [5, 30], 14 => [10, 40] } if RAPIDO
  tarefas = []
  planos.each { |dur, (passo, dias)| (2..dias).step(passo) { |n| tarefas << [dur, HOJE + n] } }
  voos = Hash.new { |h, k| h[k] = { 'd3' => {}, 'd7' => {}, 'd14' => {} } }
  trava = Mutex.new
  ok = 0
  puts "Passagens: #{tarefas.size} buscas no Kayak"
  em_paralelo(tarefas, 4) do |(dur, ida)|
    volta = ida + dur
    url = 'https://www.kayak.com.br/s/horizon/exploreapi/destinations?airport=SAO' \
          "&depart=#{ida.strftime('%Y%m%d')}&return=#{volta.strftime('%Y%m%d')}&exactDates=true" \
          '&topRightLat=80&topRightLon=180&bottomLeftLat=-80&bottomLeftLon=-180&zoomLevel=2'
    corpo = baixar(url, cab: { 'Accept' => 'application/json' })
    next unless corpo
    lista = begin
      JSON.parse(corpo)['destinations']
    rescue StandardError
      nil
    end
    next unless lista
    melhor = {}
    lista.each do |x|
      p = x.dig('flightInfo', 'price')
      cod = x.dig('airport', 'shortName')
      next unless p && p < 999_000 && codigo_para.key?(cod)
      codigo_para[cod].each do |id|
        next if melhor[id] && melhor[id][0] <= p
        cia = x['airline'].to_s.sub('Várias companhias aéreas', 'Várias')
        melhor[id] = [p.round, x['originAirportShortName'], x['flightMaxStops'], cia]
      end
    end
    trava.synchronize do
      melhor.each { |id, v| voos[id]["d#{dur}"][ida.iso8601] = v }
      ok += 1
      print "\r  #{ok}/#{tarefas.size}" if (ok % 10).zero?
    end
  end
  puts "\n  #{ok} buscas deram certo"
  raise 'Kayak não respondeu: nada foi salvo' if ok < tarefas.size * 0.3

  DEST.each { |d| voos[d['id']].each_value { |cal| cal.replace(cal.sort.to_h) } }
  cias = coletar_companhias(voos)

  resumo = ler(File.join(DADOS, 'resumo.json'), {})
  hist = ler(File.join(DADOS, 'historico.json'), {})
  DEST.each do |d|
    id = d['id']
    v = voos[id]
    # companhias: o que veio hoje + o que rodadas anteriores acharam para dias que ainda não passaram (até 7 dias atrás)
    arq = File.join(DADOS, 'voos', "#{id}.json")
    antigas = (ler(arq, {})['cias'] || {}).select do |k, x|
      ida = k.split('|')[1].to_s
      ida > HOJE.iso8601 && (x.is_a?(Array) || (x['em'].to_s >= (HOJE - 7).iso8601))
    end
    novas = (cias[id] || {}).map { |k, l| [k, { 'em' => HOJE.iso8601, 'l' => l }] }.to_h
    antigas = antigas.map { |k, x| [k, x.is_a?(Array) ? { 'em' => HOJE.iso8601, 'l' => x } : x] }.to_h
    gravar(arq, v.merge('atualizado' => AGORA.iso8601, 'cias' => antigas.merge(novas)))
    todos = v.flat_map { |k, cal| cal.map { |data, x| [x[0], data, k[1..-1].to_i, x] } }
    if todos.empty?
      resumo[id] = { 'semPreco' => true }
      next
    end
    p, data, dur, x = todos.min_by(&:first)
    sete = v['d7'].values.map(&:first).sort
    mediana = sete.empty? ? nil : sete[sete.size / 2]
    # menor preço de cada mês (viagens de 7 dias)
    meses = {}
    v['d7'].each { |dt, y| m = dt[0, 7]; meses[m] = y[0] if !meses[m] || y[0] < meses[m] }
    # para cada tamanho de viagem: menor preço geral e de cada mês (o app mostra o mesmo número no card e na tela)
    durs = {}
    v.each do |k, cal|
      next if cal.empty?
      ms = {}
      cal.each { |dt, y| m = dt[0, 7]; ms[m] = y[0] if !ms[m] || y[0] < ms[m] }
      durs[k[1..-1]] = { 'min' => cal.values.map(&:first).min, 'meses' => ms }
    end
    anterior = resumo[id] || {}
    resumo[id] = { 'min' => p, 'ida' => data, 'dias' => dur, 'orig' => x[1], 'paradas' => x[2], 'cia' => x[3],
                   'mediana' => mediana, 'meses' => meses, 'durs' => durs, 'antes' => anterior['min'],
                   'antesDurs' => (anterior['durs'] || {}).map { |k, y| [k, y['min']] }.to_h }
    h = (hist[id] ||= [])
    h.reject! { |(dt, _)| dt == HOJE.iso8601 }
    h << [HOJE.iso8601, p]
    hist[id] = h.last(120)
  end
  gravar(File.join(DADOS, 'resumo.json'), resumo)
  gravar(File.join(DADOS, 'historico.json'), hist)
end

# ---------------------------------------------------------------- companhias aéreas (Google Voos)
# O Kayak dá só a companhia mais barata de cada dia. Para os dias que o app mais mostra (o mais barato de cada
# tamanho de viagem e de cada mês), o robô busca no Google Voos o preço de cada companhia: LATAM, GOL, Azul, TAP...

def varint(n)
  b = ''.b
  loop do
    x = n & 0x7f
    n >>= 7
    b << (n > 0 ? (x | 0x80) : x).chr
    break if n.zero?
  end
  b
end

def pb(num, v)
  return varint(num << 3) + varint(v) if v.is_a?(Integer)
  v = v.b
  varint((num << 3) | 2) + varint(v.bytesize) + v
end

# endereço de busca do Google Voos (parâmetro "tfs"): ida e volta, classe econômica
def google_voos_tfs(de, para, ida, volta, adultos = 1)
  trecho = ->(dia, a, b) { pb(2, dia) + pb(13, pb(2, a)) + pb(14, pb(2, b)) }
  m = pb(3, trecho.(ida, de, para)) + pb(3, trecho.(volta, para, de))
  adultos.times { m << pb(8, 1) }
  m << pb(9, 1) << pb(19, 1)
  [m].pack('m0').tr('+/', '-_').delete('=')
end

AEROPORTO_SP = { 'Guarulhos' => 'GRU', 'Congonhas' => 'CGH', 'Viracopos' => 'VCP' }.freeze

# Do servidor do robô (nos EUA) o Google mostra os preços em dólar: converte pela cotação do dia.
def cotacao_dolar
  @cotacao ||= begin
    j = JSON.parse(baixar('https://api.frankfurter.dev/v1/latest?base=USD&symbols=BRL') || '{}')
    j.dig('rates', 'BRL') || 5.9
  rescue StandardError
    5.9
  end
end

# "1.234" ou "1,234" (milhar) -> 1234; em dólar, converte para reais
def preco_em_reais(texto, moeda)
  return nil if texto.nil? || moeda.nil?
  n = texto.gsub(/[.,](\d{3})(?!\d)/, '\1').tr(',', '.').to_f
  (moeda == 'USD' ? n * cotacao_dolar : n).round
end

# quando a página volta sem resultados, registra o que veio (título e tamanho) para entender o bloqueio
VAZIAS = Hash.new(0)
def pagina_vazia(fonte, html)
  VAZIAS[fonte] += 1
  return if VAZIAS[fonte] > 2
  titulo = html[/<title[^>]*>([^<]*)/, 1].to_s.strip[0, 80]
  warn "  #{fonte} sem resultados: \"#{titulo}\" #{html.bytesize} bytes · cartões JC21ye: #{html.scan('jsmodel="JC21ye"').size} · rótulos: #{html.scan(/aria-label="[^"]{0,25}/).map { |x| x[12..-1] }.uniq.first(25).join(' | ')}"
  c = html.split(/<div[^>]*jsmodel="JC21ye"/)[1]
  warn "    primeiro cartão: #{c.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ')[0, 500]}" if c
  warn "    rótulos do cartão: #{c.scan(/aria-label="([^"]{0,140})/).flatten.first(6).join(' | ')}" if c
end

def google_voos(para, ida, volta)
  url = "https://www.google.com/travel/flights/search?tfs=#{google_voos_tfs('SAO', para, ida, volta)}&hl=pt-BR&gl=br&curr=BRL"
  html = baixar(url, tentativas: 2)
  return nil unless html
  voos = html.scan(/aria-label="(Preço total a partir de [^"]+)"/).flatten.map do |l|
    l = CGI.unescapeHTML(l)
    cia = l[/Voos? (?:direto )?da (.+?)(?: com | sem |\.)/, 1]
    next unless cia
    saida = l[/Sai do aeroporto (.+?) às/, 1].to_s
    {
      'c' => cia,
      'p' => preco_em_reais(l[/a partir de ([\d\.,]+) /, 1], l =~ /Reais brasileiros/ ? 'BRL' : l =~ /D[óo]lares americanos/ ? 'USD' : nil),
      's' => l =~ /sem escalas|Voos? direto/i ? 0 : l[/com (\d+) parada/, 1].to_i,
      'o' => (AEROPORTO_SP.find { |k, _| saida.include?(k) } || [])[1],
      'h' => l[/às (\d{1,2}:\d{2})/, 1],
      'd' => l[/Duração total: ([^.]+)\./, 1]
    }.reject { |_, v| v.nil? }
  end.compact.select { |v| v['p'] > 0 }
  pagina_vazia('Google Voos', html) if voos.empty?
  # por companhia: o voo mais barato e, se ele tiver parada, também o direto mais barato
  voos.group_by { |v| v['c'] }.map do |_, l|
    melhor = l.min_by { |v| v['p'] }
    direto = l.select { |v| v['s'].zero? }.min_by { |v| v['p'] }
    melhor = melhor.merge('pd' => direto['p']) if direto && melhor['s'] > 0
    melhor
  end.sort_by { |v| v['p'] }.first(8)
end

def coletar_companhias(voos)
  # ordem de importância, para todos os destinos serem atendidos mesmo se o tempo acabar:
  # 1º o dia mais barato da viagem de 7 dias; 2º o de 3 e 14 dias; 3º o mais barato de cada mês (7 dias)
  niveis = [[], [], []]
  DEST.each do |d|
    v = voos[d['id']]
    v.each do |k, cal|
      next if cal.empty?
      dur = k[1..-1].to_i
      niveis[dur == 7 ? 0 : 1] << [d, dur, cal.min_by { |_, x| x[0] }[0]]
      next unless dur == 7
      cal.group_by { |dia, _| dia[0, 7] }.each_value { |l| niveis[2] << [d, 7, l.min_by { |_, x| x[0] }[0]] }
    end
  end
  tarefas = niveis.flatten(1).uniq { |(d, dur, ida)| [d['id'], dur, ida] }
  tarefas = tarefas.first(12) if RAPIDO
  puts "Companhias: #{tarefas.size} buscas no Google Voos"
  saida = Hash.new { |h, k| h[k] = {} }
  trava = Mutex.new
  ok = falhas = 0
  fim = Time.now + 600 # no máximo 10 minutos nesta parte
  em_paralelo(tarefas, 3) do |(d, dur, ida)|
    next if Time.now > fim
    next if ok + falhas >= 60 && ok < (ok + falhas) * 0.1 # o Google bloqueou de vez: para de insistir
    volta = (Date.parse(ida) + dur).iso8601
    # às vezes a página vem "carregando", sem os voos: tenta de novo
    l = nil
    3.times do |i|
      l = google_voos(d['codigos'][0], ida, volta)
      break if l && !l.empty?
      sleep 2 + i * 2
    end
    trava.synchronize do
      if l && !l.empty?
        saida[d['id']]["#{dur}|#{ida}"] = l
        ok += 1
      else
        falhas += 1
      end
    end
  end
  puts "  #{ok} deram certo, #{falhas} sem resposta"
  saida
end

# ---------------------------------------------------------------- hospedagem
# estadia de referência: sexta-feira daqui a ~4 semanas, 3 noites, 2 adultos
def estadia
  ent = HOJE + 28
  ent += 1 until ent.friday?
  [ent, ent + 3]
end

def lugar_busca(d)
  d['airbnb'].gsub('--', ', ').tr('-', ' ')
end

def numero(s)
  s.to_s.gsub(/[^\d,]/, '').tr(',', '.').to_f
end

def hoteis_google(d, ent, sai)
  q = "hotéis em #{lugar_busca(d)}"
  url = "https://www.google.com/travel/search?q=#{CGI.escape(q)}&hl=pt-BR&gl=br&curr=BRL" \
        "&checkin=#{ent}&checkout=#{sai}&adults=2"
  html = baixar(url)
  return [] unless html
  cartoes = html.split(/<div[^>]*jsmodel="JC21ye"/)[1..-1].to_a.map do |c|
    nome = CGI.unescapeHTML(c[/<h2[^>]*>([^<]+)<\/h2>/, 1].to_s)
    moeda, valor = c.match(/Preços a partir de (R\$|US\$)[[:space:]]*([\d\.,]+)/).to_a[1..2]
    preco = preco_em_reais(valor, moeda == 'US$' ? 'USD' : 'BRL')
    next if nome.empty? || !preco || preco <= 0
    ent_link = c[/href="(\/travel\/hotels\/entity\/[^"?]+)/, 1]
    nota = c[/(\d,\d) de 5/, 1]
    {
      'n' => nome,
      'p' => preco, # por noite, em reais
      'nota' => nota && nota.tr(',', '.').to_f,
      'av' => (c[/de 5 estrelas em ([\d\.]+) avalia/, 1] || '').delete('.').to_i,
      'est' => c[/Hotel (\d) estrelas/, 1].to_i,
      'off' => c[/(\d+)% abaixo/, 1].to_i,
      'img' => (c[/(https:\/\/lh\d\.googleusercontent\.com\/[^"\\\s]+)/, 1] || '').sub(/=s\d+-w\d+-h\d+/, '=s800-w800-h500'),
      'url' => ent_link ? "https://www.google.com#{ent_link}?hl=pt-BR&gl=br&curr=BRL&adults=2" : nil
    }.reject { |_, v| v.nil? || v == 0 }
  end
  r = cartoes.compact.uniq { |h| h['n'] }.first(20)
  pagina_vazia('Google Hotéis', html) if r.empty?
  r
end

def achar(o, chave, acc = [])
  case o
  when Hash
    acc << o if o.key?(chave)
    o.each_value { |v| achar(v, chave, acc) }
  when Array then o.each { |v| achar(v, chave, acc) }
  end
  acc
end

def airbnb(d, ent, sai)
  url = "https://www.airbnb.com.br/s/#{d['airbnb']}/homes?checkin=#{ent}&checkout=#{sai}&adults=2&currency=BRL"
  html = baixar(url)
  return [] unless html
  js = html[/<script id="data-deferred-state-0"[^>]*>(.*?)<\/script>/m, 1]
  return [] unless js
  noites = (sai - ent).to_i
  lista = achar(JSON.parse(js), 'structuredDisplayPrice').map do |x|
    linha = x.dig('structuredDisplayPrice', 'primaryLine') || {}
    total = numero(linha['discountedPrice'] || linha['price'])
    antes = numero(linha['originalPrice'])
    id = Base64.decode64(x.dig('demandStayListing', 'id').to_s)[/:(\d+)/, 1]
    next if total <= 0 || !id
    camas = (x.dig('structuredContent', 'mapPrimaryLine') || []).map { |m| m['body'] }.compact.join(' · ')
    nota, av = (x['avgRatingLocalized'].to_s.match(/([\d,]+)\s*\((\d+)\)/) || [])[1..2]
    nome = x['subtitle'].to_s.strip.squeeze(' ')
    {
      'id' => id,
      'n' => nome.empty? ? x['title'] : nome,
      'tipo' => x['title'].to_s.split('⋅').first.to_s.strip,
      'p' => (total / noites).round, # por noite, já com taxas
      'antes' => antes > total ? (antes / noites).round : nil,
      'nota' => nota && nota.tr(',', '.').to_f,
      'av' => av && av.to_i,
      'camas' => camas.empty? ? nil : camas,
      'fav' => (x['badges'] || []).any? { |b| b.dig('loggingContext', 'badgeType') == 'GUEST_FAVORITE' } || nil,
      'img' => (u = x.dig('contextualPictures', 0, 'picture')) && "#{u}?im_w=720"
    }.reject { |_, v| v.nil? }
  end
  lista.compact.uniq { |h| h['id'] }.first(20)
end

def coletar_hospedagem
  ent, sai = estadia
  puts "Hospedagem: #{DEST.size} destinos (#{ent} a #{sai})"
  antigo = ler(File.join(DADOS, 'hospedagem.json'), {})
  saida = { 'entrada' => ent.iso8601, 'saida' => sai.iso8601, 'atualizado' => AGORA.iso8601, 'destinos' => {} }
  trava = Mutex.new
  lista = RAPIDO ? DEST.first(4) : DEST
  em_paralelo(lista, 3) do |d|
    h = hoteis_google(d, ent, sai)
    a = airbnb(d, ent, sai)
    velho = antigo.dig('destinos', d['id']) || {}
    trava.synchronize do
      # se uma das fontes falhar hoje, fica a lista anterior
      saida['destinos'][d['id']] = { 'hoteis' => h.empty? ? velho['hoteis'] || [] : h, 'airbnb' => a.empty? ? velho['airbnb'] || [] : a }
      puts "  #{d['nome']}: #{h.size} hotéis, #{a.size} Airbnb"
    end
  end
  (antigo['destinos'] || {}).each { |k, v| saida['destinos'][k] ||= v }
  gravar(File.join(DADOS, 'hospedagem.json'), saida)
end

# ---------------------------------------------------------------- lugares (Wikipédia)
WIKI_UA = { 'User-Agent' => 'AppViagens/1.0 (app pessoal de roteiros)' }.freeze

WIKI = 'https://pt.wikipedia.org/w/api.php?action=query&format=json&prop=extracts%7Cpageimages%7Cinfo&inprop=url' \
       '&exintro=1&explaintext=1&exsentences=3&exlimit=20&piprop=thumbnail&pithumbsize=800&pilimit=20&redirects=1'

# a Wikipédia limita pedidos: um de cada vez, com pausa, e 20 lugares por pedido
def wiki_json(url)
  sleep 1.5
  JSON.parse(baixar(url, cab: WIKI_UA) || '{}')
rescue JSON::ParserError
  {}
end

def wiki_pagina(pg)
  return nil unless pg && !pg['missing'] && !pg['extract'].to_s.empty?
  return nil if pg['extract'] =~ /pode (referir-se|significar|ser)\b.{0,20}:/ # página de desambiguação
  texto = pg['extract'].gsub(/\s*\([^()]*\)/, '').gsub(/\s+/, ' ').strip
  { 'txt' => texto[0, 420], 'img' => pg.dig('thumbnail', 'source'), 'url' => pg['fullurl'] }.reject { |_, v| v.nil? }
end

COMUNS = %w[praia igreja parque museu lagoa cidade centro historico bairro mercado palacio ponte torre plaza praca
             catedral castelo cerro monte ilha ilhas vale lago jardim teatro grande nacional municipal santa santo
             sao rio baia morro rua].freeze

def sem_acento(s)
  s.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase
end

def parecido?(nome, titulo)
  palavras = sem_acento(nome.sub(/ \(.*\)$/, '')).scan(/[a-z]{4,}/) - COMUNS
  t = sem_acento(titulo)
  palavras.any? { |w| t.include?(w) }
end

FOTO_RUIM = /logo|flag|bandeira|escudo|brasao|coat_of|seal|map|mapa|locat|local[A-Z_]|states|montage|diagram|chart|senado|castigo|icon|banner|dimos/i.freeze

def foto_boa?(url)
  arq = CGI.unescape(url.to_s.split('?').first.to_s.split('/').last.to_s)
  arq =~ /\.jpe?g$/i && arq !~ FOTO_RUIM
end

# primeira foto de verdade entre as imagens de uma página
def foto_da_pagina(lingua, titulo)
  j = wiki_json("https://#{lingua}.wikipedia.org/w/api.php?action=query&format=json&generator=images&gimlimit=40" \
                "&prop=imageinfo&iiprop=url&iiurlwidth=960&titles=#{CGI.escape(titulo)}")
  pg = (j.dig('query', 'pages') || {}).values.sort_by { |x| x['title'].to_s }
  achada = pg.find { |x| x['title'].to_s =~ /\.jpe?g$/i && x['title'] !~ FOTO_RUIM && x.dig('imageinfo', 0, 'thumburl') }
  achada && achada.dig('imageinfo', 0, 'thumburl')
end

def coletar_lugares
  arq = File.join(DADOS, 'lugares.json')
  lug = ler(arq, {})
  lug.reject! { |_, v| v.empty? } # tenta de novo o que não achou da última vez
  faltam = {}
  DEST.each do |d|
    cidade = d['nome'].split(' e ').first
    faltam[d['capa']] ||= cidade unless lug.key?(d['capa'])
    d['lugares'].each { |(n, _)| faltam[n] ||= cidade unless lug.key?(n) }
  end
  puts "Lugares: #{faltam.size} para buscar na Wikipédia"
  faltam.keys.each_slice(20) do |grupo|
    j = wiki_json("#{WIKI}&titles=#{CGI.escape(grupo.join('|'))}")
    q = j['query'] || {}
    # o nome pedido pode virar outro título (acentos, redirecionamento): segue o caminho até a página final
    troca = {}
    (q['normalized'] || []).each { |x| troca[x['from']] = x['to'] }
    (q['redirects'] || []).each { |x| troca[x['from']] = x['to'] }
    por_titulo = (q['pages'] || {}).values.map { |pg| [pg['title'], pg] }.to_h
    grupo.each do |n|
      t = n
      3.times { t = troca[t] || t }
      r = wiki_pagina(por_titulo[t])
      lug[n] = r if r
    end
    print "\r  #{lug.size} encontrados"
  end
  # o que não achou pelo nome exato: busca "nome + cidade"
  faltam.each do |n, cidade|
    next if lug.key?(n)
    j = wiki_json("#{WIKI}&generator=search&gsrlimit=3&gsrsearch=#{CGI.escape("#{n.sub(/ \(.*\)$/, '')} #{cidade}")}")
    # só aceita uma página cujo título tenha uma palavra marcante do nome (evita cair em página errada)
    pg = (j.dig('query', 'pages') || {}).values.sort_by { |x| x['index'] || 9 }.find { |x| parecido?(n, x['title']) }
    lug[n] = wiki_pagina(pg) || {}
  end
  # foto ruim (logotipo, bandeira, mapa, desenho) ou sem foto: procura outra
  todos = DEST.flat_map { |d| ([d['capa']] + d['lugares'].map(&:first)).map { |n| [n, d['nome'].split(' e ').first] } }.uniq
  todos.each { |n, _| lug[n].delete('img') if lug[n] && lug[n]['img'] && !foto_boa?(lug[n]['img']) }
  faltam_foto = todos.reject { |n, _| lug[n] && lug[n]['img'] }
  puts "\n  procurando #{faltam_foto.size} fotos" unless faltam_foto.empty?
  en = WIKI.sub('pt.wikipedia', 'en.wikipedia')
  faltam_foto.each do |n, cidade|
    curto = n.sub(/ \(.*\)$/, '')
    # 1. outra foto da própria página em português
    pt = lug[n] && lug[n]['url'] && CGI.unescape(lug[n]['url'].split('/wiki/').last.to_s).tr('_', ' ')
    img = pt && foto_da_pagina('pt', pt)
    # 2. a página em inglês: foto principal, ou outra foto dela
    unless img
      e = wiki_json("#{en}&titles=#{CGI.escape(curto)}")
      p2 = (e.dig('query', 'pages') || {}).values.first
      if !p2 || p2['missing']
        e = wiki_json("#{en}&generator=search&gsrlimit=3&gsrsearch=#{CGI.escape("#{curto} #{cidade}")}")
        p2 = (e.dig('query', 'pages') || {}).values.sort_by { |x| x['index'] || 9 }.find { |x| parecido?(n, x['title']) }
      end
      if p2 && !p2['missing']
        img = p2.dig('thumbnail', 'source')
        img = foto_da_pagina('en', p2['title']) unless img && foto_boa?(img)
      end
    end
    (lug[n] ||= {})['img'] = img if img
  end
  puts
  gravar(arq, lug)
  sem = lug.select { |_, v| v.empty? || !v['img'] }.keys
  puts "  sem foto: #{sem.join(', ')}" unless sem.empty?
end

coletar_lugares if SO.nil? || SO == 'lugares'
coletar_hospedagem if SO.nil? || SO == 'hoteis'
coletar_voos if SO.nil? || SO == 'voos'
info = ler(File.join(DADOS, 'info.json'), {})
info['atualizado'] = AGORA.iso8601 if SO.nil? || SO == 'voos'
gravar(File.join(DADOS, 'info.json'), info)
puts 'Pronto.'
