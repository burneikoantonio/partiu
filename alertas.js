// Robô de avisos do Partiu: roda na nuvem depois de cada coleta e manda notificações (Web Push) para os celulares.
//
//  - cada aparelho tem um "canal" (código aleatório, aparece no Perfil do app);
//  - ao ativar as notificações, o app avisa no tópico de registro (REGISTRO) que aquele canal existe;
//  - avisos de preço e a inscrição de notificação ficam no tópico "<canal>-prefs" do ntfy.sh.
// O robô guarda tudo em .prefs/ (cache privado do GitHub, fora do site público).
//
// Variáveis: VAPID_PUBLIC, VAPID_PRIVATE, SITE_URL, REGISTRO, TESTE_TODOS=1, DRY_RUN=1 (só imprime)
const fs = require('fs');
const path = require('path');

const PREFS = path.join(__dirname, '.prefs');
fs.mkdirSync(PREFS, { recursive: true });
const ler = (f, padrao) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return padrao; } };
const gravar = (f, x) => fs.writeFileSync(f, JSON.stringify(x));
const SITE = (process.env.SITE_URL || '').replace(/\/$/, '');
const REGISTRO = process.env.REGISTRO;
const DRY = !!process.env.DRY_RUN;
const brl = v => 'R$ ' + Math.round(v).toLocaleString('pt-BR');
const MES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const data = s => `${+s.slice(8, 10)} ${MES[+s.slice(5, 7) - 1]}`;

const agora = new Date();
const hoje = agora.toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
const hora = +agora.toLocaleString('en-US', { timeZone: 'America/Sao_Paulo', hour: 'numeric', hour12: false }) % 24;
const SILENCIO = hora >= 23 || hora < 7;

async function ntfy(topico) {
  try {
    const r = await fetch(`https://ntfy.sh/${topico}/json?poll=1&since=all`);
    return (await r.text()).trim().split('\n').filter(Boolean).map(l => JSON.parse(l)).filter(m => m.event === 'message')
      .map(m => { try { return JSON.parse(m.message); } catch (e) { return null; } }).filter(Boolean);
  } catch (e) { console.error('ntfy falhou:', topico, e.message); return []; }
}

let webpush = null;
if (process.env.VAPID_PUBLIC && process.env.VAPID_PRIVATE) {
  try {
    webpush = require('web-push');
    webpush.setVapidDetails(SITE || 'https://example.com', process.env.VAPID_PUBLIC, process.env.VAPID_PRIVATE);
  } catch (e) { console.error('web-push indisponível:', e.message); }
}

(async () => {
  const canais = new Set(ler(path.join(PREFS, 'canais.json'), []));
  const testes = new Set();
  if (REGISTRO) for (const m of await ntfy(REGISTRO)) {
    if (typeof m.canal !== 'string' || !/^[\w-]{8,64}$/.test(m.canal)) continue;
    canais.add(m.canal);
    if (m.teste) testes.add(m.canal);
  }
  gravar(path.join(PREFS, 'canais.json'), [...canais]);
  if (process.env.TESTE_TODOS) for (const c of canais) testes.add(c);

  const dados = f => ler(path.join(__dirname, 'app', f), {});
  const { destinos } = dados('destinos.json');
  const nomes = Object.fromEntries((destinos || []).map(d => [d.id, d.nome]));
  const resumo = dados('data/resumo.json');
  const voos = id => dados(`data/voos/${id}.json`);

  // o melhor preço que atende ao aviso: mês escolhido (se houver) e tamanho de viagem (se houver)
  function melhor(id, a) {
    const v = voos(id);
    let m = null;
    for (const dur of a.dur ? [a.dur] : [3, 7, 14]) {
      for (const [ida, x] of Object.entries(v['d' + dur] || {})) {
        if (a.mes && !ida.startsWith(a.mes)) continue;
        if (!m || x[0] < m.p) m = { p: x[0], ida, dur, orig: x[1], cia: x[3] };
      }
    }
    return m;
  }

  // mural de cada grupo "Juntos"
  const murais = new Map();
  async function mural(grupo) {
    if (murais.has(grupo)) return murais.get(grupo);
    const m = ler(path.join(PREFS, `mural-${grupo}.json`), { itens: {}, apagados: [] });
    const apagados = new Set(m.apagados);
    for (const x of await ntfy(`${grupo}-mural`)) {
      if (x.tipo === 'rec' && x.chave) m.itens[x.chave] ||= x;
      if (x.tipo === 'voto' && x.chave && m.itens[x.chave]) (m.itens[x.chave].votos ||= {})[x.de] = x.sim;
      if (x.tipo === 'del' && x.chave) apagados.add(x.chave);
      if (x.tipo === 'copia') { for (const r of x.itens || []) m.itens[r.chave] ||= r; for (const k of x.apagados || []) apagados.add(k); }
    }
    for (const k of apagados) delete m.itens[k];
    m.itens = Object.fromEntries(Object.values(m.itens).filter(r => agora - r.em < 90 * 864e5).sort((a, b) => b.em - a.em).slice(0, 150).map(r => [r.chave, r]));
    m.apagados = [...apagados].slice(-300);
    murais.set(grupo, m);
    return m;
  }

  let total = 0;
  for (const canal of canais) {
    const arqP = path.join(PREFS, `prefs-${canal}.json`), arqE = path.join(PREFS, `enviados-${canal}.json`);
    let prefs = ler(arqP, null);
    const subs = [...(prefs?.pushes || [])];
    for (const p of await ntfy(`${canal}-prefs`)) {
      for (const s of p.pushes || []) subs.push(s);
      if (!prefs || (p.em || 0) > (prefs.em || 0)) prefs = { ...p, mortos: prefs?.mortos };
    }
    if (!prefs) { console.log(`Canal ${canal.slice(0, 6)}…: sem preferências ainda`); continue; }
    const mortos = new Set(prefs.mortos || []);
    prefs.pushes = [...new Map(subs.filter(s => s?.endpoint && !mortos.has(s.endpoint)).map(s => [s.endpoint, s])).values()];
    const enviados = ler(arqE, {});
    for (const [k, d] of Object.entries(enviados)) if ((agora - new Date(d)) > 30 * 864e5) delete enviados[k];

    let ok = 0, erro = 0;
    async function enviar(title, body, url, tag, image) {
      total++;
      if (DRY || !webpush) { console.log(`[${canal.slice(0, 6)}…] ${title} — ${body.replace(/\n/g, ' | ')}`); return; }
      for (const s of [...prefs.pushes]) {
        try { await webpush.sendNotification(s, JSON.stringify({ title, body, url, tag, image }), { TTL: 86400 }); ok++; }
        catch (e) {
          erro++;
          if (e.statusCode === 404 || e.statusCode === 410) { prefs.pushes = prefs.pushes.filter(x => x.endpoint !== s.endpoint); (prefs.mortos ||= []).push(s.endpoint); }
          else console.error('Web Push falhou:', e.statusCode, e.body || e.message);
        }
      }
    }

    if (testes.has(canal)) await enviar('Partiu', 'Teste: as notificações estão chegando. Toque para abrir o app.', SITE || './', 'teste');

    if (!SILENCIO) {
      // 1. avisos de preço: chegou no preço pedido, ou baixou 10% desde que o aviso foi criado
      for (const [id, a] of Object.entries(prefs.alertas || {})) {
        if (!nomes[id]) continue;
        const m = melhor(id, a);
        if (!m) continue;
        const alvo = a.max && m.p <= a.max;
        const caiu = a.base && m.p <= a.base * 0.9;
        if (!alvo && !caiu) continue;
        const chave = `voo|${id}|${Math.round(m.p / 50)}`; // só avisa de novo se mudar pelo menos R$ 50
        if (enviados[chave]) continue;
        await enviar(alvo ? `${nomes[id]} chegou no seu preço` : `${nomes[id]}: baixou ${Math.round((1 - m.p / a.base) * 100)}%`,
          `${brl(m.p)} ida e volta por pessoa\n${data(m.ida)}, ${m.dur} dias · sai de ${m.orig} · ${m.cia}`,
          SITE ? `${SITE}/#destino=${id}` : './', `voo-${id}`);
        enviados[chave] = hoje;
      }
    }

    // 1b. destinos curtidos: avisa quando o menor preço baixa 10% em relação a quando curtiu (ou ao último aviso)
    if (!SILENCIO) {
      for (const [id, base] of Object.entries(prefs.curtidas || {})) {
        if (!nomes[id] || !base || (prefs.alertas || {})[id]) continue; // quem tem aviso de preço já é tratado acima
        const m = melhor(id, {});
        if (!m || m.p > base * 0.9) continue;
        const chave = `curt|${id}|${Math.round(m.p / 50)}`;
        if (enviados[chave]) continue;
        await enviar(`${nomes[id]}: baixou ${Math.round((1 - m.p / base) * 100)}%`,
          `${brl(m.p)} ida e volta por pessoa (era ${brl(base)})\n${data(m.ida)}, ${m.dur} dias · sai de ${m.orig}`,
          SITE ? `${SITE}/#destino=${id}` : './', `voo-${id}`);
        enviados[chave] = hoje;
      }
    }

    // 2. viagens mandadas por alguém do grupo (até 5 por rodada)
    const g = /^vg-[a-z0-9]{8,}$/.test(prefs.grupo || '') ? await mural(prefs.grupo) : null;
    if (!SILENCIO && g) {
      let n = 0;
      for (const r of Object.values(g.itens).sort((a, b) => a.em - b.em)) {
        const chave = `rec|${r.chave}`;
        if (r.canal === canal || enviados[chave]) continue;
        if (agora - r.em > 3 * 864e5) { enviados[chave] = hoje; continue; }
        if (n >= 5) break;
        await enviar(`${String(r.de || 'Alguém').slice(0, 20)} mandou uma viagem`,
          `${String(r.t).slice(0, 60)}${r.ida ? ` · ${data(r.ida)} a ${data(r.volta)}` : ''}${r.pix ? `\n${brl(r.pix)} por pessoa` : ''}${r.msg ? `\n“${String(r.msg).slice(0, 120)}”` : ''}`,
          SITE ? `${SITE}/#juntos` : './', `rec-${r.chave}`, r.img);
        enviados[chave] = hoje; n++;
      }
    }

    gravar(arqE, enviados);
    gravar(arqP, prefs);
    if (!DRY) try { await fetch(`https://ntfy.sh/${canal}-prefs`, { method: 'POST', body: JSON.stringify({ ...prefs, mortos: undefined }) }); } catch (e) {}
    console.log(`Canal ${canal.slice(0, 6)}…: ${prefs.pushes.length} aparelho(s), ${ok} enviada(s), ${erro} erro(s)`);
  }
  // guarda os murais e republica uma cópia no ntfy (que apaga depois de 12h), em pedaços de até ~3 KB
  for (const [grupo, m] of murais) {
    gravar(path.join(PREFS, `mural-${grupo}.json`), m);
    if (DRY) continue;
    const pedacos = [[]];
    let tam = 0;
    for (const r of Object.values(m.itens)) {
      const t = JSON.stringify(r).length;
      if (tam + t > 3200 && pedacos[pedacos.length - 1].length) { pedacos.push([]); tam = 0; }
      pedacos[pedacos.length - 1].push(r); tam += t;
    }
    for (const [i, itens] of pedacos.entries()) {
      try { await fetch(`https://ntfy.sh/${grupo}-mural`, { method: 'POST', body: JSON.stringify({ tipo: 'copia', itens, apagados: i === 0 ? m.apagados.slice(-20) : [] }) }); } catch (e) {}
    }
  }
  console.log(`${canais.size} canal(is), ${murais.size} grupo(s), ${total} aviso(s)${SILENCIO ? ' (horário de silêncio)' : ''}`);
})();
