// Juntos: grupo de amigos/família que planeja viagens junto.
// O grupo é um código secreto. As viagens mandadas ficam no tópico "<grupo>-mural" do ntfy.sh;
// o robô guarda uma cópia, republica (o ntfy apaga depois de 12h) e avisa os outros no celular.

S.mural ||= {}; // cópia local: { chave: viagem recomendada }

function novoCodigo(prefixo) {
  return prefixo + Array.from(crypto.getRandomValues(new Uint8Array(10)), b => 'abcdefghijkmnpqrstuvwxyz23456789'[b % 32]).join('');
}
function criarGrupo() {
  if (!S.nome) return toast('Escreva seu nome primeiro');
  S.juntos = novoCodigo('vg-'); salvar(); sincronizar(); telaJuntos(); convidar();
}
function entrarGrupo(cod) {
  cod = (cod || '').trim().replace(/^.*entrar=/, '');
  if (!/^vg-[a-z0-9]{8,}$/.test(cod)) return toast('Código inválido');
  S.juntos = cod; salvar(); sincronizar(); toast('Você entrou no grupo');
}
function sairGrupo() {
  if (!confirm('Sair do grupo? As viagens continuam lá para os outros.')) return;
  delete S.juntos; S.mural = {}; salvar(); sincronizar(); telaJuntos();
}
async function convidar() {
  const url = location.origin + location.pathname + '#entrar=' + S.juntos;
  const texto = `${S.nome || 'Eu'} te chamou para o grupo de viagens: a gente manda passagens e destinos um pro outro. Abra no celular:`;
  try { if (navigator.share) await navigator.share({ title: 'Partiu', text: texto, url }); else { await navigator.clipboard.writeText(texto + ' ' + url); toast('Convite copiado'); } } catch (e) {}
}

// ---------- mural ----------
async function lerMural() {
  if (!S.juntos) return;
  try {
    const r = await fetch(`https://ntfy.sh/${S.juntos}-mural/json?poll=1&since=all`);
    const msgs = (await r.text()).trim().split('\n').filter(Boolean).map(l => { try { return JSON.parse(JSON.parse(l).message); } catch (e) { return null; } }).filter(Boolean);
    const apagados = new Set();
    for (const m of msgs) {
      if (m.tipo === 'copia') for (const x of m.itens || []) S.mural[x.chave] ||= x;
      if (m.tipo === 'copia') for (const k of m.apagados || []) apagados.add(k);
      if (m.tipo === 'rec' && m.chave) S.mural[m.chave] ||= m;
      if (m.tipo === 'voto' && m.chave && S.mural[m.chave]) (S.mural[m.chave].votos ||= {})[m.de] = m.sim;
      if (m.tipo === 'del' && m.chave) apagados.add(m.chave);
    }
    for (const k of apagados) delete S.mural[k];
    salvar();
  } catch (e) {}
}
// manda a viagem que está na tela (destino + datas + preço) para o grupo
async function recomendar(id) {
  const d = DEST.get(id);
  if (!S.juntos) { toast('Crie ou entre num grupo primeiro'); return irAba('juntos'); }
  if (!S.nome) { toast('Escreva seu nome no Perfil primeiro'); return irAba('perfil'); }
  const vg = escolherViagem(d, VOOS.get(id) || {});
  const msg = prompt('Quer mandar um recado junto? (opcional)', '');
  if (msg === null) return;
  const rec = { tipo: 'rec', chave: S.canal + '-' + Date.now(), id, t: d.nome, img: capa(d), ida: vg.ida || null, volta: vg.ida ? volta(vg) : null, pix: vg.x ? vg.x[0] : RES[id]?.min || null, pessoas: S.pessoas, msg: msg.slice(0, 200), de: S.nome, canal: S.canal, em: Date.now() };
  S.mural[rec.chave] = rec; salvar();
  try { await fetch(`https://ntfy.sh/${S.juntos}-mural`, { method: 'POST', body: JSON.stringify(rec) }); toast('Mandado! O grupo recebe um aviso.'); }
  catch (e) { toast('Sem internet: tente de novo'); }
}
async function votar(chave, sim) {
  const r = S.mural[chave]; if (!r) return;
  (r.votos ||= {})[S.nome || S.canal] = sim; salvar(); telaJuntos(false);
  try { await fetch(`https://ntfy.sh/${S.juntos}-mural`, { method: 'POST', body: JSON.stringify({ tipo: 'voto', chave, de: S.nome || S.canal, sim }) }); } catch (e) {}
}
async function apagarRec(chave) {
  delete S.mural[chave]; salvar(); telaJuntos();
  try { await fetch(`https://ntfy.sh/${S.juntos}-mural`, { method: 'POST', body: JSON.stringify({ tipo: 'del', chave }) }); } catch (e) {}
}
function abrirRec(chave) {
  const r = S.mural[chave];
  if (r.ida && r.volta) { S.sel = null; S.modo = 'exato'; S.ida = r.ida; S.volta = r.volta; }
  if (r.pessoas) S.pessoas = r.pessoas;
  salvar(); abrir(r.id, 'voos');
}

function quando(ms) {
  const m = Math.round((Date.now() - ms) / 60000);
  return m < 60 ? `há ${Math.max(1, m)} min` : m < 1440 ? `há ${Math.round(m / 60)} h` : `há ${Math.round(m / 1440)} dia(s)`;
}
async function telaJuntos(atualizar) {
  const app = document.getElementById('app');
  if (!S.juntos) {
    app.innerHTML = `<div class="tela"><h1>Juntos</h1>
      <div class="texto">Planeje com amigos ou família: cada um manda passagens e destinos para o grupo, todos votam e recebem um aviso no celular.
      <div class="sub" style="margin-top:8px">Cada pessoa usa o app no próprio celular, com os próprios avisos de preço.</div></div>
      <h2>Seu nome</h2><input class="campo" id="nomeJ" placeholder="Como o grupo vai te ver" value="${esc(S.nome || '')}" onchange="S.nome=this.value.trim().slice(0,20);salvar();sincronizar()">
      <div class="acoes" style="flex-direction:column">
        <button class="btn cheio" onclick="S.nome=document.getElementById('nomeJ').value.trim().slice(0,20);salvar();criarGrupo()">Criar grupo e convidar</button>
        <button class="btn fraco cheio" onclick="const c=prompt('Cole o código ou o link do convite');if(c){entrarGrupo(c);telaJuntos(true)}">Tenho um convite</button>
      </div></div>`;
    return;
  }
  if (atualizar !== false) lerMural().then(() => { if (ABA === 'juntos' && !location.hash.includes('destino=')) telaJuntos(false); });
  const itens = Object.values(S.mural).sort((a, b) => b.em - a.em);
  app.innerHTML = `<div class="tela"><div class="linha"><h1>Juntos</h1><span style="display:flex;gap:16px"><button class="ordem" onclick="convidar()">Convidar</button><button class="ordem" style="color:var(--sec)" onclick="sairGrupo()">Sair</button></span></div>
    ${itens.length ? itens.map(r => {
      const meu = r.canal === S.canal;
      const agora = RES[r.id]?.min;
      const votos = Object.entries(r.votos || {});
      const sim = votos.filter(([, v]) => v).map(([n]) => n), nao = votos.filter(([, v]) => !v).map(([n]) => n);
      const meuVoto = (r.votos || {})[S.nome || S.canal];
      return `<div class="peca">
        <button class="foto" onclick="abrirRec('${esc(r.chave)}')">${r.img ? `<img src="${esc(r.img)}" alt="" style="width:100%;height:100%;object-fit:cover" onerror="this.remove()">` : ''}</button>
        <div class="info">
          <div class="rotulo">${meu ? 'Você mandou' : esc(r.de) + ' mandou'} · ${quando(r.em)}</div>
          <div class="nm" onclick="abrirRec('${esc(r.chave)}')">${esc(r.t)}</div>
          <div class="serve">${r.ida ? `${dataCurta(r.ida)} → ${dataCurta(r.volta)}` : 'datas flexíveis'}${r.pessoas ? ` · ${r.pessoas} ${r.pessoas > 1 ? 'pessoas' : 'pessoa'}` : ''}</div>
          ${r.msg ? `<div class="serve" style="color:var(--txt)">“${esc(r.msg)}”</div>` : ''}
          ${votos.length ? `<div class="serve">${sim.length ? `👍 ${sim.map(esc).join(', ')}` : ''}${sim.length && nao.length ? ' · ' : ''}${nao.length ? `👎 ${nao.map(esc).join(', ')}` : ''}</div>` : ''}
          <div style="display:flex;gap:14px">
            <button class="acao" style="${meuVoto === true ? '' : 'color:var(--sec)'}" onclick="votar('${esc(r.chave)}',true)">👍 Topo</button>
            <button class="acao" style="${meuVoto === false ? '' : 'color:var(--sec)'}" onclick="votar('${esc(r.chave)}',false)">👎 Não</button>
            ${meu ? `<button class="acao" style="color:var(--sec)" onclick="apagarRec('${esc(r.chave)}')">Apagar</button>` : ''}
          </div>
        </div>
        <div class="pr">${brl(r.pix)}<div class="sub" style="font-weight:400">por pessoa</div>${agora && r.pix && agora < r.pix - 20 ? `<small style="color:var(--verde);font-size:12px">agora desde ${brl(agora)}</small>` : ''}</div>
      </div>`; }).join('') : `<div class="vazio">Nada no grupo ainda.<br>Abra um destino e toque em <b>Mandar pro grupo</b>.</div>`}
  </div>`;
}
