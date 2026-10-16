'use strict';

/* =====================================================================
   Koe, Oberfläche. Vanilla JS, keine Abhängigkeiten, komplett offline.

   Aufbau:
     1. Brücke            senden() zu Swift, window.koe von Swift
     2. Hilfsfunktionen   Escaping, Zeit- und Zahlenformate, Icons
     3. Zustand           z (von Swift) und ui (nur lokal)
     4. Ansichten         viewDiktate, viewMeetings, viewDatei, viewEinstellungen, viewDetail
     5. Rendern           render() mit Fokus- und Scroll-Schutz
     6. Aktionen          Klicks und Eingaben (Event-Delegation)
     7. Mock              Vorschau im Browser ohne Swift
   ===================================================================== */


/* ---------- 1. Brücke ---------- */

const BRIDGE = window.webkit?.messageHandlers?.koe ?? null;
let mockSenden = () => {};

function senden(cmd, daten = {}) {
  if (BRIDGE) BRIDGE.postMessage({ cmd, ...daten });
  else mockSenden(cmd, daten);
}


/* ---------- 2. Hilfsfunktionen ---------- */

const $ = (sel, root = document) => root.querySelector(sel);

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);
const p2 = (n) => String(n).padStart(2, '0');
const fmtZahl = (n) => Number(n || 0).toLocaleString('de-DE');

const MONATE = ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sept.', 'Okt.', 'Nov.', 'Dez.'];

/** heute 14:32 / gestern 09:10 / 12. Okt., 18:04 */
function fmtZeit(ms) {
  const d = new Date(ms);
  const jetzt = new Date();
  const hm = `${p2(d.getHours())}:${p2(d.getMinutes())}`;
  const tag0 = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((tag0(jetzt) - tag0(d)) / 86400000);
  if (diff === 0) return `heute ${hm}`;
  if (diff === 1) return `gestern ${hm}`;
  const jahr = d.getFullYear() !== jetzt.getFullYear() ? ` ${d.getFullYear()}` : '';
  return `${d.getDate()}. ${MONATE[d.getMonth()]}${jahr}, ${hm}`;
}

/** 4 s / 12 Min. / 1 Std. 8 Min. */
function fmtDauer(sek) {
  sek = Number(sek) || 0;
  if (sek < 60) return `${Math.max(1, Math.round(sek))} s`;
  const gesamtMin = Math.round(sek / 60);
  if (gesamtMin < 60) return `${gesamtMin} Min.`;
  const h = Math.floor(gesamtMin / 60);
  const m = gesamtMin % 60;
  return m ? `${h} Std. ${m} Min.` : `${h} Std.`;
}

/** mm:ss bzw. h:mm:ss */
function fmtMarke(sek) {
  const s = Math.max(0, Math.floor(Number(sek) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}:${p2(m)}:${p2(s % 60)}` : `${p2(m)}:${p2(s % 60)}`;
}

const TASTEN = {
  'rechte-option': { kurz: 'Rechte ⌥', satz: 'Rechte ⌥ gedrückt halten' },
  'fn': { kurz: 'fn', satz: 'fn gedrückt halten' },
  'rechte-befehl': { kurz: 'Rechte ⌘', satz: 'Rechte ⌘ gedrückt halten' },
};
const tasteInfo = (taste) => TASTEN[taste] ?? TASTEN['rechte-option'];

function sprecherName(id, namen = {}) {
  if (namen[id]) return namen[id];
  if (id === 'ich') return 'Ich';
  const m = /^s(\d+)$/.exec(id);
  return m ? `Sprecher ${m[1]}` : String(id);
}

/** Ich = Blau, alle anderen reihum aus Cyan-dark, Coral-dark und zwei Grautönen. */
const SPRECHER_FARBEN = ['var(--cyan-dark)', 'var(--orange-dark)', 'var(--ink-3)', 'var(--ink-4)'];
function sprecherFarben(ids) {
  const karte = {};
  let i = 0;
  for (const id of ids) karte[id] = id === 'ich' ? 'var(--blue)' : SPRECHER_FARBEN[i++ % SPRECHER_FARBEN.length];
  return karte;
}

const ICONS = {
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  meeting: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6"/><path d="M16 5.2a3.2 3.2 0 0 1 0 5.6M18 14.3c1.8.8 3 2.6 3 4.7"/>',
  datei: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 15v-2M12 17v-6M15 15v-2"/>',
  regler: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
  kopieren: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h8"/>',
  korb: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
  runter: '<path d="m6 9 6 6 6-6"/>',
  rechts: '<path d="m9 6 6 6-6 6"/>',
  zurueck: '<path d="M15 6l-6 6 6 6"/>',
  haken: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  ordner: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  speichern: '<path d="M12 4v11M7 11l5 5 5-5M5 20h14"/>',
  suche: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4-4"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  stopp: '<rect x="6.5" y="6.5" width="11" height="11" rx="2"/>',
  warn: '<path d="M12 4 2.8 19.5h18.4z"/><path d="M12 10v4M12 17v.01"/>',
  neustart: '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6"/>',
  hoch: '<path d="M12 16V5M7 9l5-5 5 5M5 20h14"/>',
  schloss: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  stift: '<path d="M4 20l1-4L16 5l3 3L8 19z"/>',
  pfeil: '<path d="M5 12h14M13 6l6 6-6 6"/>',
};
function ico(name, size = 18) {
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] ?? ''}</svg>`;
}


/* ---------- 3. Zustand ---------- */

/** Letzter kompletter Zustand von Swift (koe.zustand). */
let z = null;

/** Nur lokale Oberflächen-Zustände. Nichts davon geht an Swift, außer über senden(). */
const ui = {
  ansicht: 'diktate',      // diktate | meetings | datei | einstellungen | detail
  zurueckZu: 'meetings',   // wohin der Zurück-Knopf der Detailansicht führt
  detailId: null,
  t: null,                 // geladenes Transkript (koe.transkript) der Detailansicht
  draft: { suche: '', mtitel: '', wort: '', von: '', nach: '', tsuche: '' },
  rename: null,            // { typ: 'titel' | 'sprecher', id, wert }
  offenRoh: new Set(),     // Diktate mit aufgeklapptem Rohtext
  loeschBereit: null,      // Diktat-ID, die einen zweiten Klick zum Löschen wartet
  kopiert: null,           // Schlüssel des Knopfs, der kurz "Kopiert" zeigt
  modal: null,             // { titel, text, ok, aktion }
  pegel: { mikro: 0, system: 0 },
  fokus: null,             // gewünschter Fokus nach dem nächsten Rendern
};

const find = (zz, id) => (zz?.transkripte ?? []).find((x) => x.id === id);
const einst = () => z?.einstellungen ?? {};
const systemtonAn = () => einst().systemton !== false;

function fehlendeRechte() {
  const r = z?.rechte ?? {};
  const aus = [];
  if (r.mikrofon !== 'ja') aus.push('Mikrofon');
  if (r.bedienungshilfen !== 'ja') aus.push('Bedienungshilfen');
  if (r.bildschirm !== 'ja' && systemtonAn()) aus.push('Bildschirm');
  return aus;
}

function seitMs(seit) {
  if (!seit) return Date.now();
  return seit < 1e11 ? seit * 1000 : seit; // Sekunden oder Millisekunden seit 1970
}


/* ---------- 4. Ansichten ---------- */

function kopf(titel, rechts = '') {
  return `<header class="kopf"><h1>${esc(titel)}</h1>${rechts}</header>`;
}

function sucheFeld(key, wert, platzhalter, zaehler = '') {
  return `<label class="suche">${ico('suche', 15)}<input type="text" data-key="${key}" data-feld="${key}" placeholder="${esc(platzhalter)}" value="${esc(wert)}" autocomplete="off" spellcheck="false">${zaehler}</label>`;
}

function leer(icon, text, klein = false) {
  return `<div class="leer${klein ? ' klein' : ''}">${klein ? '' : `<div class="kreis">${ico(icon, 22)}</div>`}<p>${text}</p></div>`;
}

/* --- Diktate --- */

function viewDiktate() {
  const alle = [...(z.diktate ?? [])].sort((a, b) => b.zeit - a.zeit);
  const q = ui.draft.suche.trim().toLowerCase();
  const liste = q ? alle.filter((d) => `${d.text} ${d.roh} ${d.app ?? ''}`.toLowerCase().includes(q)) : alle;

  let inhalt;
  if (!alle.length) {
    const t = tasteInfo(einst().taste);
    inhalt = leer('mic', `${esc(t.satz)} und sprechen. Zweimal kurz tippen startet das Diktat freihändig.`);
  } else if (!liste.length) {
    inhalt = leer('suche', 'Kein Diktat gefunden.');
  } else {
    inhalt = liste.map(diktatKarte).join('');
  }
  return kopf('Diktate', alle.length ? sucheFeld('suche', ui.draft.suche, 'Diktate durchsuchen') : '') + inhalt;
}

function diktatKarte(d) {
  const offen = ui.offenRoh.has(d.id);
  const bereit = ui.loeschBereit === d.id;
  const kopiert = ui.kopiert === `d:${d.id}`;
  return `
  <article class="eintrag">
    <div class="eintrag-kopf">
      <span class="zeit">${esc(fmtZeit(d.zeit))}</span>
      ${d.app ? `<span class="app-name">${esc(d.app)}</span>` : ''}
      ${d.dauer ? `<span class="dauer">${esc(fmtDauer(d.dauer))}</span>` : ''}
    </div>
    <p class="eintrag-text">${esc(d.text)}</p>
    ${offen ? `<div class="roh"><div class="etikett">Rohtext</div><p>${esc(d.roh || 'Kein Rohtext gespeichert.')}</p></div>` : ''}
    <div class="aktionen">
      <button class="btn-text${kopiert ? ' ok' : ''}" data-act="diktat-kopieren" data-id="${esc(d.id)}">${ico(kopiert ? 'haken' : 'kopieren', 15)}${kopiert ? 'Kopiert' : 'Kopieren'}</button>
      <button class="btn-text" data-act="roh-toggle" data-id="${esc(d.id)}" aria-expanded="${offen}">${ico('runter', 15).replace('<svg ', `<svg class="rot-chevron${offen ? ' auf' : ''}" `)}Rohtext</button>
      <span class="rechts"><button class="btn-text ${bereit ? 'bereit' : 'gefahr'}" data-act="diktat-loeschen" data-id="${esc(d.id)}">${ico('korb', 15)}${bereit ? 'Wirklich löschen' : 'Löschen'}</button></span>
    </div>
  </article>`;
}

/* --- Meetings --- */

function viewMeetings() {
  const aufnahme = z.aufnahme ?? {};
  const laeuft = aufnahme.art === 'meeting';
  const alle = [...(z.transkripte ?? [])].sort((a, b) => b.zeit - a.zeit);
  return (
    kopf('Meetings') +
    (laeuft ? laufendeKarte(aufnahme) : startKarte(aufnahme)) +
    `<div class="sek-kopf"><h2><i class="punkt"></i>Transkripte</h2></div>` +
    (alle.length
      ? alle.map((t) => transZeile(t)).join('')
      : leer('', 'Noch keine Transkripte. Starte oben eine Aufnahme oder lege eine Datei ab.', true))
  );
}

function startKarte(aufnahme) {
  const r = z.rechte ?? {};
  const besetzt = !!aufnahme.art; // z. B. ein Diktat läuft gerade
  const keinMikro = r.mikrofon === 'nein';
  let hinweis = '';
  if (besetzt) hinweis = '<p class="hinweis-klein">Ein Diktat läuft gerade. Danach kannst du aufnehmen.</p>';
  else if (keinMikro) hinweis = '<p class="hinweis-klein">Das Mikrofon-Recht fehlt. <button data-act="nav" data-ziel="einstellungen">Zu den Einstellungen</button></p>';
  else if (systemtonAn() && r.bildschirm === 'nein') hinweis = '<p class="hinweis-klein">Für den Ton vom Mac fehlt das Recht Bildschirmaufnahme. <button data-act="nav" data-ziel="einstellungen">Zu den Einstellungen</button></p>';
  return `
  <section class="karte start-raster">
    <div>
      <label class="etikett-feld" for="mtitel">Titel</label>
      <input class="in" id="mtitel" type="text" data-key="mtitel" data-feld="mtitel" placeholder="z. B. Erstgespräch Müller Maschinenbau" value="${esc(ui.draft.mtitel)}" autocomplete="off" spellcheck="false">
    </div>
    <div class="start-unten">
      <div class="schalter-zeile">
        <button class="schalter" role="switch" aria-checked="${systemtonAn()}" aria-label="Ton vom Mac mitschneiden" data-act="systemton"></button>
        <span>Ton vom Mac mitschneiden (Zoom, Teams, Meet)</span>
      </div>
      <button class="btn btn-primary" data-act="meeting-start"${besetzt || keinMikro ? ' disabled' : ''}>${ico('mic', 16)}Aufnahme starten</button>
    </div>
    ${hinweis}
  </section>`;
}

function laufendeKarte(aufnahme) {
  return `
  <section class="karte">
    <div class="laeuft-kopf"><span class="live"><i class="live-punkt"></i>Aufnahme läuft</span><span class="titel">${esc(aufnahme.titel || 'Meeting')}</span></div>
    <div class="timer" data-timer>00:00</div>
    <div class="pegel-block">
      <div class="pegel-zeile"><span>Mikrofon</span><div class="pegel"><b data-pegel="mikro"></b></div></div>
      <div class="pegel-zeile"><span>Mac-Ton</span><div class="pegel sys"><b data-pegel="system"></b></div></div>
    </div>
    <div class="knoepfe">
      <button class="btn btn-primary" data-act="meeting-stop">${ico('stopp', 16)}Beenden und transkribieren</button>
      <button class="btn btn-ghost" data-act="meeting-verwerfen-frage">Verwerfen</button>
    </div>
  </section>`;
}

function transZeile(t, statisch = false) {
  const st = t.status;
  const meta = [fmtZeit(t.zeit)];
  if (t.dauer) meta.push(fmtDauer(t.dauer));
  if (st === 'fertig' && t.woerter) meta.push(`${fmtZahl(t.woerter)} Wörter`);
  if (st === 'fertig' && (t.sprecher?.length ?? 0) > 1) meta.push(`${t.sprecher.length} Sprecher`);
  meta.push(t.quelle === 'datei' ? 'Datei' : 'Meeting');

  let unten = '';
  let status = '';
  if (st === 'laeuft') {
    const f = Math.max(0, Math.min(1, Number(t.fortschritt) || 0));
    unten = `<div class="fortschritt"><div class="balken"><b style="width:${(f * 100).toFixed(1)}%"></b></div><div class="text"><span>${esc(t.schritt || 'Wird transkribiert')}</span><span>${Math.round(f * 100)} %</span></div></div>`;
    status = '<span class="status st-laeuft">Läuft</span>';
  } else if (st === 'wartet') {
    status = '<span class="status st-wartet">Wartet</span>';
  } else if (st === 'aufnahme') {
    status = '<span class="status st-aufnahme"><i class="live-punkt"></i>Aufnahme</span>';
  } else if (st === 'fehler') {
    unten = `<span class="trans-fehler">${esc(t.fehler || 'Die Transkription ist fehlgeschlagen.')}</span>`;
    status = '<span class="status st-fehler">Fehler</span>';
  } else {
    status = `<span class="status st-fertig">${ico('rechts', 16)}</span>`;
  }

  const inner = `
    <span class="trans-ikone">${ico(t.quelle === 'datei' ? 'datei' : 'meeting', 18)}</span>
    <span class="trans-haupt">
      <span class="trans-titel">${esc(t.titel || 'Ohne Titel')}</span>
      <span class="trans-meta">${esc(meta.join(' · '))}</span>
      ${unten}
    </span>
    ${status}`;
  if (st === 'aufnahme' || statisch) return `<div class="trans statisch">${inner}</div>`;
  return `<button class="trans" data-act="trans-oeffnen" data-id="${esc(t.id)}">${inner}</button>`;
}

/* --- Datei --- */

function viewDatei() {
  const dateien = [...(z.transkripte ?? [])].filter((t) => t.quelle === 'datei').sort((a, b) => b.zeit - a.zeit);
  return (
    kopf('Datei') +
    `<section class="drop" id="drop">
      <div class="kreis">${ico('hoch', 24)}</div>
      <h2>Audio- oder Videodatei hierher ziehen</h2>
      <p class="klein">oder von der Festplatte auswählen</p>
      <button class="btn btn-primary" data-act="datei-waehlen">Datei auswählen</button>
    </section>
    <p class="lokal-hinweis">${ico('schloss', 15)}Läuft komplett lokal. Nichts verlässt den Mac.</p>
    <div class="sek-kopf"><h2><i class="punkt cyan"></i>Zuletzt hochgeladen</h2></div>` +
    (dateien.length ? dateien.map((t) => transZeile(t)).join('') : leer('', 'Noch keine Dateien.', true))
  );
}

/* --- Einstellungen --- */

function schalterReihe(feld, titel, text) {
  const an = !!einst()[feld];
  return `<div class="reihe">
    <div class="reihe-text"><b>${esc(titel)}</b><span>${esc(text)}</span></div>
    <button class="schalter" role="switch" aria-checked="${an}" aria-label="${esc(titel)}" data-act="schalter" data-feld="${feld}"></button>
  </div>`;
}

function segmente(feld, optionen, aktuell) {
  return `<div class="seg" role="group">${optionen
    .map(([wert, label]) => `<button data-act="seg" data-feld="${feld}" data-wert="${esc(wert)}" aria-pressed="${wert === aktuell}">${esc(label)}</button>`)
    .join('')}</div>`;
}

function viewEinstellungen() {
  const e = einst();
  const woerter = e.woerter ?? [];
  const ersetzungen = e.ersetzungen ?? [];
  const rechte = z.rechte ?? {};
  const dienste = z.dienste ?? {};

  const RECHTE = [
    ['mikrofon', 'Mikrofon', 'Zum Diktieren und für Meetings'],
    ['bedienungshilfen', 'Bedienungshilfen', 'Für das Tastenkürzel und das Einfügen des Texts'],
    ['bildschirm', 'Bildschirmaufnahme', 'Für den Ton vom Mac'],
  ];
  const DIENSTE = [
    ['whisper', 'Spracherkennung'],
    ['llm', 'Aufräumen'],
    ['sprecher', 'Sprechertrennung'],
  ];
  const WORT = { bereit: 'bereit', startet: 'startet', fehlt: 'fehlt', fehler: 'Fehler' };

  return (
    kopf('Einstellungen') +

    `<div class="sek-kopf" style="margin-top:0"><h2><i class="punkt"></i>Diktat</h2></div>
    <div class="gruppe">
      <div class="reihe">
        <div class="reihe-text"><b>Tastenkürzel</b><span>Gedrückt halten zum Sprechen, zweimal tippen für freihändig</span></div>
        ${segmente('taste', [['rechte-option', 'Rechte ⌥'], ['fn', 'fn'], ['rechte-befehl', 'Rechte ⌘']], e.taste)}
      </div>
      <div class="reihe">
        <div class="reihe-text"><b>Sprache</b></div>
        ${segmente('sprache', [['de', 'Deutsch'], ['en', 'Englisch'], ['ja', 'Japanisch'], ['auto', 'Automatisch']], e.sprache)}
      </div>
      ${schalterReihe('aufraeumen', 'Text aufräumen', 'Füllwörter raus, Satzzeichen rein')}
      ${schalterReihe('einfuegen', 'Automatisch einfügen', 'Der Text landet dort, wo dein Cursor steht')}
      ${schalterReihe('toene', 'Töne', 'Kurzer Ton beim Start und Ende')}
    </div>

    <div class="sek-kopf"><h2><i class="punkt cyan"></i>Wörterbuch</h2></div>
    <div class="gruppe"><div class="reihe stapel" style="padding:16px 0">
      <div class="reihe-text" style="margin-bottom:12px"><span style="margin:0">Eigennamen und Fachbegriffe, die richtig geschrieben werden sollen</span></div>
      <div class="chips">${woerter
        .map((w, i) => `<span class="chip"><span>${esc(w)}</span><button data-act="wort-del" data-i="${i}" aria-label="${esc(w)} entfernen">${ico('x', 12)}</button></span>`)
        .join('')}</div>
      <div class="add-zeile">
        <input class="in" type="text" data-key="wort" data-feld="wort" data-enter="wort-add" placeholder="Neuer Begriff" value="${esc(ui.draft.wort)}" autocomplete="off" spellcheck="false">
        <button class="btn btn-ghost" data-act="wort-add">${ico('plus', 15)}Hinzufügen</button>
      </div>
    </div></div>

    <div class="sek-kopf"><h2><i class="punkt"></i>Ersetzungen</h2></div>
    <div class="gruppe"><div class="reihe stapel" style="padding:16px 0">
      <div class="reihe-text" style="margin-bottom:10px"><span style="margin:0">Wenn Koe etwas falsch versteht, wird es automatisch ersetzt</span></div>
      <div class="ers-liste">${ersetzungen
        .map((r, i) => `<div class="ers"><span class="von">${esc(r.von)}</span><span class="pf">${ico('pfeil', 14)}</span><span class="nach">${esc(r.nach)}</span><button class="icon-knopf" data-act="ers-del" data-i="${i}" aria-label="Ersetzung entfernen">${ico('x', 14)}</button></div>`)
        .join('')}</div>
      <div class="add-zeile">
        <input class="in" type="text" data-key="von" data-feld="von" data-enter="ers-add" placeholder="Statt …" value="${esc(ui.draft.von)}" autocomplete="off" spellcheck="false" aria-label="Wird ersetzt">
        <span class="pfeil">${ico('pfeil', 15)}</span>
        <input class="in" type="text" data-key="nach" data-feld="nach" data-enter="ers-add" placeholder="… dies" value="${esc(ui.draft.nach)}" autocomplete="off" spellcheck="false" aria-label="Ersetzt durch">
        <button class="btn btn-ghost" data-act="ers-add">${ico('plus', 15)}Hinzufügen</button>
      </div>
    </div></div>

    <div class="sek-kopf"><h2><i class="punkt cyan"></i>Berechtigungen</h2></div>
    <div class="gruppe">${RECHTE.map(([key, name, text]) => {
      const s = rechte[key] ?? 'offen';
      const label = s === 'ja' ? 'Erlaubt' : s === 'nein' ? 'Fehlt' : 'Noch nicht gefragt';
      const dot = s === 'ja' ? 'sd' : s === 'nein' ? 'sd sd-fehler' : 'sd sd-fehlt';
      return `<div class="reihe">
        <div class="reihe-text"><b>${name}</b><span>${text}</span></div>
        <div class="reihe-rechts">
          <span class="recht-status ${s === 'nein' ? 'nein' : ''}"><i class="${dot}"></i>${label}</span>
          <button class="btn ${s === 'ja' ? 'btn-ghost' : 'btn-primary'} btn-klein" data-act="recht" data-recht="${key}">Öffnen</button>
        </div>
      </div>`;
    }).join('')}</div>

    <div class="sek-kopf"><h2><i class="punkt"></i>Dienste</h2><button class="btn btn-ghost btn-klein" data-act="dienste-neustart">${ico('neustart', 14)}Neu starten</button></div>
    <div class="gruppe">${DIENSTE.map(([key, name]) => {
      const d = dienste[key] ?? { status: 'fehlt', text: '' };
      return `<div class="reihe dienst-reihe">
        <div class="reihe-text"><b>${name}</b>${d.text ? `<span>${esc(d.text)}</span>` : ''}</div>
        <span class="recht-status ${d.status === 'fehler' ? 'nein' : ''}" style="min-width:0"><i class="sd sd-${esc(d.status)}"></i>${esc(WORT[d.status] ?? d.status)}</span>
      </div>`;
    }).join('')}</div>

    <div class="sek-kopf"><h2><i class="punkt cyan"></i>Speicherort</h2></div>
    <div class="gruppe"><div class="reihe stapel" style="padding:16px 0">
      <div class="pfad">${esc(z.speicherort || '')}</div>
      <div style="margin-top:12px"><button class="btn btn-ghost btn-klein" data-act="ordner">${ico('ordner', 14)}Im Finder zeigen</button></div>
    </div></div>`
  );
}

/* --- Transkript-Detail --- */

function gruppiere(segs) {
  const aus = [];
  for (const s of segs) {
    const letzter = aus[aus.length - 1];
    const text = String(s.text ?? '').trim();
    if (letzter && letzter.sprecher === s.sprecher) {
      letzter.text += ' ' + text;
      letzter.ende = s.ende;
    } else {
      aus.push({ sprecher: s.sprecher, start: s.start, ende: s.ende, text });
    }
  }
  return aus;
}

function hervorheben(text, q) {
  if (!q) return esc(text);
  const re = new RegExp(`(${q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi');
  return text.split(re).map((teil, i) => (i % 2 ? `<mark>${esc(teil)}</mark>` : esc(teil))).join('');
}

function viewDetail() {
  const tr = find(z, ui.detailId);
  if (!tr) return kopf('Transkript') + leer('', 'Dieses Transkript gibt es nicht mehr.', true);

  const knopf = (act, icon, label, key = '') => {
    const kopiert = key && ui.kopiert === key;
    return `<button class="btn btn-ghost btn-klein" data-act="${act}">${ico(kopiert ? 'haken' : icon, 14)}${kopiert ? 'Kopiert' : label}</button>`;
  };

  const titel =
    ui.rename?.typ === 'titel'
      ? `<input class="in titel-eingabe" data-key="rename" data-feld="rename" data-enter="rename-ok" value="${esc(ui.rename.wert)}" aria-label="Titel" autocomplete="off" spellcheck="false">`
      : `<button class="titel-knopf" data-act="titel-edit" title="Umbenennen"><span>${esc(tr.titel || 'Ohne Titel')}</span>${ico('stift', 16)}</button>`;

  const meta = [fmtZeit(tr.zeit)];
  if (tr.dauer) meta.push(fmtDauer(tr.dauer));
  meta.push(tr.quelle === 'datei' ? 'Datei' : 'Meeting');
  if (tr.status === 'fertig' && tr.woerter) meta.push(`${fmtZahl(tr.woerter)} Wörter`);

  const t = ui.t && ui.t.id === tr.id ? ui.t : null;
  const fertig = tr.status === 'fertig';
  const q = ui.draft.tsuche.trim();

  // Treffer zählen und Abschnitte bauen
  let koerper;
  let zaehler = '';
  if (!fertig) {
    koerper = transZeile(tr, true);
  } else if (!t) {
    koerper = leer('', 'Transkript wird geladen …', true);
  } else if (!(t.segmente ?? []).length) {
    koerper = leer('', 'In dieser Aufnahme wurde kein Text erkannt.', true);
  } else {
    const gruppen = gruppiere(t.segmente);
    const ids = [];
    for (const s of t.segmente) if (!ids.includes(s.sprecher)) ids.push(s.sprecher);
    const farben = sprecherFarben(ids);
    const namen = t.namen ?? {};
    const re = q ? new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi') : null;
    let treffer = 0;
    const bloecke = gruppen.map((g) => {
      const n = re ? (g.text.match(re) ?? []).length : 0;
      treffer += n;
      const gedimmt = q && !n ? ' gedimmt' : '';
      const editiert = ui.rename?.typ === 'sprecher' && ui.rename.id === g.sprecher;
      const name = editiert
        ? `<input class="in sprecher-eingabe" data-key="rename" data-feld="rename" data-enter="rename-ok" value="${esc(ui.rename.wert)}" aria-label="Sprechername" autocomplete="off" spellcheck="false">`
        : `<button class="sprecher" style="--c:${farben[g.sprecher]}" data-act="sprecher-edit" data-sid="${esc(g.sprecher)}" title="Sprecher umbenennen"><i></i>${esc(sprecherName(g.sprecher, namen))}</button>`;
      return `<div class="abschnitt${gedimmt}">
        <div class="abschnitt-kopf">${name}<span class="zeitmarke">${fmtMarke(g.start)}</span></div>
        <p class="abschnitt-text">${hervorheben(g.text, q)}</p>
      </div>`;
    });
    if (q) zaehler = `<span class="zaehler">${treffer} Treffer</span>`;
    koerper = `<div class="protokoll">${bloecke.join('')}</div>`;
  }

  return `
  <button class="btn-text zurueck" data-act="zurueck">${ico('zurueck', 15)}Zurück</button>
  <div class="detail-kopf">
    ${titel}
    <div class="meta-zeile">${meta.map((m) => `<span>${esc(m)}</span>`).join('<i></i>')}</div>
  </div>
  <div class="detail-aktionen">
    ${fertig ? knopf('t-kopieren', 'kopieren', 'Kopieren', `t:${tr.id}`) : ''}
    ${fertig ? knopf('t-export', 'speichern', 'Als Markdown speichern') : ''}
    ${knopf('t-finder', 'ordner', 'Im Finder zeigen')}
    <button class="btn btn-ghost btn-klein" style="color:var(--orange-dark)" data-act="t-loeschen-frage">${ico('korb', 14)}Löschen</button>
    ${fertig && t?.segmente?.length ? sucheFeld('tsuche', ui.draft.tsuche, 'Im Transkript suchen', zaehler) : ''}
  </div>
  ${koerper}`;
}

/* --- Navigation, Dialog --- */

function renderNav() {
  const aktiv = ui.ansicht === 'detail' ? ui.zurueckZu : ui.ansicht;
  const trs = z.transkripte ?? [];
  const arbeitet = (f) => trs.filter((t) => (t.status === 'laeuft' || t.status === 'wartet') && f(t)).length;
  const zahlen = { meetings: arbeitet(() => true), datei: arbeitet((t) => t.quelle === 'datei') };
  const PUNKTE = [
    ['diktate', 'Diktate', 'mic'],
    ['meetings', 'Meetings', 'meeting'],
    ['datei', 'Datei', 'datei'],
    ['einstellungen', 'Einstellungen', 'regler'],
  ];
  const WORT = { bereit: 'bereit', startet: 'startet', fehlt: 'fehlt', fehler: 'Fehler' };
  const DIENSTE = [['whisper', 'Sprache'], ['llm', 'Aufräumen'], ['sprecher', 'Sprecher']];
  const fehlt = fehlendeRechte();
  const art = z.aufnahme?.art;

  return `
  <div class="marke"><b>Koe</b><span lang="ja">声</span></div>
  ${PUNKTE.map(([key, label, icon]) => `
    <button class="nav-punkt" data-act="nav" data-ziel="${key}"${aktiv === key ? ' aria-current="page"' : ''}>
      ${ico(icon, 18)}<span>${label}</span>${zahlen[key] ? `<span class="zahl">${zahlen[key]}</span>` : ''}
    </button>`).join('')}
  <div class="nav-unten">
    ${art ? `<button class="rec-chip" data-act="nav" data-ziel="${art === 'meeting' ? 'meetings' : 'diktate'}"><i class="live-punkt"></i>${art === 'meeting' ? 'Aufnahme' : 'Diktat'}${art === 'meeting' ? '<span data-timer>00:00</span>' : ''}</button>` : ''}
    ${fehlt.length ? `<button class="warnung" data-act="nav" data-ziel="einstellungen">${ico('warn', 15)}<span>Recht fehlt: ${esc(fehlt.join(', '))}</span></button>` : ''}
    <button class="dienste-zeile" data-act="nav" data-ziel="einstellungen" aria-label="Dienste, zu den Einstellungen">
      <div class="etikett">Dienste</div>
      ${DIENSTE.map(([key, name]) => {
        const s = z.dienste?.[key]?.status ?? 'fehlt';
        return `<div class="dienst"><i class="sd sd-${esc(s)}"></i><span>${name}</span><em>${esc(WORT[s] ?? s)}</em></div>`;
      }).join('')}
    </button>
  </div>`;
}

function renderModal() {
  const m = ui.modal;
  if (!m) return '';
  return `<div class="schleier" data-act="modal-aus"><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dlg-t">
    <h2 id="dlg-t">${esc(m.titel)}</h2>
    <p>${esc(m.text)}</p>
    <div class="knoepfe">
      <button class="btn btn-ghost" data-key="dlg-abbruch" data-act="modal-abbruch">Abbrechen</button>
      <button class="btn btn-gefahr" data-act="modal-ok">${esc(m.ok)}</button>
    </div>
  </div></div>`;
}


/* ---------- 5. Rendern ---------- */

const navEl = $('#nav');
const mainEl = $('#main');
const viewEl = $('#view');
const modalEl = $('#modal-root');

function setHtml(node, html) {
  if (node._html === html) return false;
  node.innerHTML = html;
  node._html = html;
  return true;
}

function merkeFokus() {
  const a = document.activeElement;
  if (a?.dataset?.key) return { key: a.dataset.key, s: a.selectionStart, e: a.selectionEnd };
  return null;
}

function stelleFokus(alt) {
  if (ui.fokus) {
    const el = document.querySelector(`[data-key="${ui.fokus.key}"]`);
    if (el) {
      el.focus({ preventScroll: true });
      if (ui.fokus.alles) el.select();
    }
    ui.fokus = null;
    return;
  }
  if (!alt) return;
  const el = document.querySelector(`[data-key="${alt.key}"]`);
  if (el && document.activeElement !== el) {
    el.focus({ preventScroll: true });
    try { el.setSelectionRange(alt.s, alt.e); } catch { /* kein Textfeld */ }
  }
}

function render() {
  if (!z) {
    setHtml(viewEl, '');
    return;
  }
  const fokusAlt = merkeFokus();
  setHtml(navEl, renderNav());
  const VIEWS = { diktate: viewDiktate, meetings: viewMeetings, datei: viewDatei, einstellungen: viewEinstellungen, detail: viewDetail };
  setHtml(viewEl, (VIEWS[ui.ansicht] ?? viewDiktate)());
  const modalNeu = setHtml(modalEl, renderModal());
  if (modalNeu && ui.modal) ui.fokus = { key: 'dlg-abbruch' };
  stelleFokus(fokusAlt);
  updatePegel();
  updateTimer();
}

function updatePegel() {
  for (const k of ['mikro', 'system']) {
    const b = $(`[data-pegel="${k}"]`);
    if (!b) continue;
    const v = Math.max(0, Math.min(1, Number(ui.pegel[k]) || 0));
    b.style.transform = `scaleX(${v})`;
    b.classList.toggle('laut', v > 0.9);
  }
}

function updateTimer() {
  const a = z?.aufnahme;
  if (!a || a.art !== 'meeting') return;
  const text = fmtMarke((Date.now() - seitMs(a.seit)) / 1000);
  for (const el of document.querySelectorAll('[data-timer]')) if (el.textContent !== text) el.textContent = text;
}
setInterval(updateTimer, 250);

function toast(text, art = 'info') {
  const wrap = $('#toasts');
  const el = document.createElement('div');
  el.className = `toast${art === 'fehler' ? ' fehler' : ''}`;
  el.innerHTML = `<i class="sd"></i><span>${esc(text)}</span>`;
  wrap.appendChild(el);
  setTimeout(() => el.classList.add('raus'), 3750);
  setTimeout(() => el.remove(), 4000);
}

function zeigeKurz(key) {
  ui.kopiert = key;
  render();
  setTimeout(() => { if (ui.kopiert === key) { ui.kopiert = null; render(); } }, 1500);
}

function geheZu(ansicht) {
  ui.ansicht = ansicht;
  ui.rename = null;
  ui.t = null;
  ui.draft.tsuche = '';
  ui.loeschBereit = null;
  mainEl.scrollTop = 0;
  render();
}


/* ---------- 6. Aktionen ---------- */

function aendereEinst(fn) {
  const neu = structuredClone(einst());
  fn(neu);
  z.einstellungen = neu;
  senden('einstellungen.speichern', { einstellungen: neu });
  render();
}

function oeffneDetail(id) {
  ui.zurueckZu = ui.ansicht === 'datei' ? 'datei' : 'meetings';
  ui.detailId = id;
  ui.t = null;
  ui.rename = null;
  ui.draft.tsuche = '';
  ui.ansicht = 'detail';
  mainEl.scrollTop = 0;
  const tr = find(z, id);
  if (tr?.status === 'fertig') senden('transkript.laden', { id });
  render();
}

function frage(m) {
  ui.modal = m;
  render();
}

function commitRename() {
  const r = ui.rename;
  if (!r) return;
  ui.rename = null; // zuerst leeren, damit ein Blur beim Neuzeichnen nichts doppelt sendet
  const wert = r.wert.trim();
  const tr = find(z, ui.detailId);
  if (r.typ === 'titel') {
    if (wert && tr && wert !== tr.titel) {
      tr.titel = wert;
      senden('transkript.umbenennen', { id: tr.id, titel: wert });
    }
  } else if (ui.t) {
    const namen = { ...(ui.t.namen ?? {}) };
    const alt = namen[r.id] ?? '';
    if (wert && wert !== sprecherName(r.id, {})) namen[r.id] = wert;
    else delete namen[r.id];
    if ((namen[r.id] ?? '') !== alt) {
      ui.t.namen = namen;
      senden('transkript.sprecher', { id: ui.t.id, namen });
    }
  }
  render();
}

const aktionen = {
  nav: (el) => geheZu(el.dataset.ziel),
  'trans-oeffnen': (el) => oeffneDetail(el.dataset.id),
  zurueck: () => geheZu(ui.zurueckZu),

  // Diktate
  'diktat-kopieren': (el) => { senden('diktat.kopieren', { id: el.dataset.id }); zeigeKurz(`d:${el.dataset.id}`); },
  'roh-toggle': (el) => {
    const id = el.dataset.id;
    ui.offenRoh.has(id) ? ui.offenRoh.delete(id) : ui.offenRoh.add(id);
    render();
  },
  'diktat-loeschen': (el) => {
    const id = el.dataset.id;
    if (ui.loeschBereit === id) {
      ui.loeschBereit = null;
      senden('diktat.loeschen', { id });
      z.diktate = (z.diktate ?? []).filter((d) => d.id !== id);
      render();
      return;
    }
    ui.loeschBereit = id;
    render();
    setTimeout(() => { if (ui.loeschBereit === id) { ui.loeschBereit = null; render(); } }, 3000);
  },

  // Meetings
  systemton: () => aendereEinst((e) => { e.systemton = !(e.systemton !== false); }),
  'meeting-start': () => {
    senden('meeting.start', { titel: ui.draft.mtitel.trim(), systemton: systemtonAn() });
    ui.draft.mtitel = '';
  },
  'meeting-stop': () => senden('meeting.stop'),
  'meeting-verwerfen-frage': () =>
    frage({ titel: 'Aufnahme verwerfen?', text: 'Die bisherige Aufnahme wird gelöscht und nicht transkribiert.', ok: 'Verwerfen', aktion: () => senden('meeting.verwerfen') }),

  // Datei
  'datei-waehlen': () => senden('datei.waehlen'),

  // Einstellungen
  schalter: (el) => aendereEinst((e) => { e[el.dataset.feld] = !e[el.dataset.feld]; }),
  seg: (el) => aendereEinst((e) => { e[el.dataset.feld] = el.dataset.wert; }),
  'wort-add': () => {
    const w = ui.draft.wort.trim();
    if (!w) return;
    ui.draft.wort = '';
    ui.fokus = { key: 'wort' };
    aendereEinst((e) => {
      e.woerter = e.woerter ?? [];
      if (!e.woerter.some((x) => x.toLowerCase() === w.toLowerCase())) e.woerter.push(w);
    });
  },
  'wort-del': (el) => aendereEinst((e) => { e.woerter.splice(Number(el.dataset.i), 1); }),
  'ers-add': () => {
    const von = ui.draft.von.trim();
    const nach = ui.draft.nach.trim();
    if (!von || !nach) { ui.fokus = { key: von ? 'nach' : 'von' }; render(); return; }
    ui.draft.von = '';
    ui.draft.nach = '';
    ui.fokus = { key: 'von' };
    aendereEinst((e) => {
      e.ersetzungen = e.ersetzungen ?? [];
      const i = e.ersetzungen.findIndex((r) => r.von.toLowerCase() === von.toLowerCase());
      if (i >= 0) e.ersetzungen[i] = { von, nach };
      else e.ersetzungen.push({ von, nach });
    });
  },
  'ers-del': (el) => aendereEinst((e) => { e.ersetzungen.splice(Number(el.dataset.i), 1); }),
  recht: (el) => senden('recht.oeffnen', { recht: el.dataset.recht }),
  'dienste-neustart': () => senden('dienste.neustart'),
  ordner: () => senden('ordner.oeffnen'),

  // Detail
  'titel-edit': () => {
    const tr = find(z, ui.detailId);
    ui.rename = { typ: 'titel', id: tr.id, wert: tr.titel || '' };
    ui.fokus = { key: 'rename', alles: true };
    render();
  },
  'sprecher-edit': (el) => {
    const id = el.dataset.sid;
    ui.rename = { typ: 'sprecher', id, wert: sprecherName(id, ui.t?.namen) };
    ui.fokus = { key: 'rename', alles: true };
    render();
  },
  'rename-ok': () => commitRename(),
  't-kopieren': () => { senden('transkript.kopieren', { id: ui.detailId }); zeigeKurz(`t:${ui.detailId}`); },
  't-export': () => senden('transkript.exportieren', { id: ui.detailId }),
  't-finder': () => senden('transkript.finder', { id: ui.detailId }),
  't-loeschen-frage': () => {
    const tr = find(z, ui.detailId);
    const id = ui.detailId;
    frage({
      titel: 'Transkript löschen?',
      text: `„${tr?.titel || 'Ohne Titel'}“ wird endgültig gelöscht.`,
      ok: 'Löschen',
      aktion: () => {
        senden('transkript.loeschen', { id });
        z.transkripte = (z.transkripte ?? []).filter((x) => x.id !== id);
        geheZu(ui.zurueckZu);
      },
    });
  },

  // Dialog
  'modal-ok': () => { const m = ui.modal; ui.modal = null; render(); m?.aktion?.(); },
  'modal-abbruch': () => { ui.modal = null; render(); },
  'modal-aus': (el, e) => { if (e.target === el) { ui.modal = null; render(); } },
};

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  aktionen[el.dataset.act]?.(el, e);
});

/* Eingaben: Entwürfe merken. Nur Suchfelder zeichnen sofort neu (Filter). */
const FELDER = {
  suche: (v) => { ui.draft.suche = v; return true; },
  tsuche: (v) => { ui.draft.tsuche = v; return true; },
  mtitel: (v) => { ui.draft.mtitel = v; return false; },
  wort: (v) => { ui.draft.wort = v; return false; },
  von: (v) => { ui.draft.von = v; return false; },
  nach: (v) => { ui.draft.nach = v; return false; },
  rename: (v) => { if (ui.rename) ui.rename.wert = v; return false; },
};

function eingabe(el) {
  const fn = FELDER[el.dataset.feld];
  if (fn && fn(el.value)) render();
}
document.addEventListener('input', (e) => { if (!e.isComposing) eingabe(e.target); });
document.addEventListener('compositionend', (e) => eingabe(e.target));

document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.isComposing && e.target.dataset?.enter) {
    e.preventDefault();
    aktionen[e.target.dataset.enter]?.(e.target, e);
  } else if (e.key === 'Escape') {
    if (ui.modal) { ui.modal = null; render(); }
    else if (ui.rename) { ui.rename = null; render(); }
  }
});

document.addEventListener('focusout', (e) => {
  if (e.target.dataset?.feld === 'rename' && ui.rename) commitRename();
});

/* Dateien über das Fenster ziehen: nur Optik, das Ablegen fängt die Swift-Seite ab. */
let ziehZaehler = 0;
window.addEventListener('dragenter', (e) => { e.preventDefault(); ziehZaehler++; $('#drop')?.classList.add('ziehen'); });
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('dragleave', () => { if (--ziehZaehler <= 0) { ziehZaehler = 0; $('#drop')?.classList.remove('ziehen'); } });
window.addEventListener('drop', (e) => { e.preventDefault(); ziehZaehler = 0; $('#drop')?.classList.remove('ziehen'); });


/* Schnittstelle für Swift */
window.koe = {
  zustand(neu) {
    const alt = z;
    z = neu;
    if (z.aufnahme?.art !== 'meeting') ui.pegel = { mikro: 0, system: 0 };
    if (ui.ansicht === 'detail') {
      const tr = find(z, ui.detailId);
      if (!tr) {
        ui.ansicht = ui.zurueckZu;
        ui.t = null;
        ui.rename = null;
      } else if (tr.status === 'fertig' && find(alt, ui.detailId)?.status !== 'fertig') {
        senden('transkript.laden', { id: tr.id });
      }
    }
    render();
  },
  transkript(t) {
    if (t.id === ui.detailId) { ui.t = t; render(); }
  },
  pegel(p) {
    ui.pegel = { mikro: p?.mikro ?? 0, system: p?.system ?? 0 };
    updatePegel();
  },
  meldung(m) {
    toast(m?.text ?? '', m?.art ?? 'info');
  },
};


/* ---------- 7. Mock für die Vorschau im Browser ---------- */

function startMock() {
  const jetzt = Date.now();
  const MIN = 60e3, STD = 3600e3, TAG = 86400e3;

  const erstgespraech = [
    ['ich', 'Hallo zusammen, schön, dass wir uns heute Zeit nehmen. Ich würde gern kurz klären, wo bei euch gerade die meiste Handarbeit anfällt.'],
    ['s1', 'Gerne. Bei uns laufen jeden Tag etwa vierzig Anfragen per Mail ein, und die werden alle von Hand in unser ERP übertragen.'],
    ['s1', 'Das kostet uns grob zwei Stunden pro Tag, und Fehler passieren natürlich auch.'],
    ['s2', 'Dazu kommt, dass die Angebote jedes Mal neu in Word gebaut werden. Das dauert pro Angebot fast eine Stunde.'],
    ['ich', 'Verstehe. Wie viele Angebote sind das pro Woche?'],
    ['s2', 'Ungefähr fünfzehn bis zwanzig, je nach Saison.'],
    ['ich', 'Dann reden wir über mehr als zwanzig Stunden pro Woche, die sich automatisieren lassen.'],
    ['s1', 'Das klingt ehrlich gesagt zu schön, um wahr zu sein. Was passiert mit unseren Kundendaten?'],
    ['ich', 'Wichtige Frage. Die Verarbeitung läuft bei uns komplett auf Servern in Deutschland, und die Transkription der Gespräche sogar lokal auf meinem Rechner.'],
    ['ich', 'Es verlässt also nichts die EU, und wir schließen einen Auftragsverarbeitungsvertrag ab.'],
    ['s1', 'Das beruhigt mich. Unser Datenschutzbeauftragter wird dazu bestimmt noch Fragen haben.'],
    ['s2', 'Kann man das auch erst mal klein ausprobieren, bevor wir alles umstellen?'],
    ['ich', 'Ja, genau so würde ich anfangen. Wir nehmen einen einzigen Prozess, zum Beispiel den Posteingang für Anfragen.'],
    ['ich', 'Der Rollout läuft in drei Schritten: Analyse, Einführung und danach der Betrieb.'],
    ['s2', 'Wie lange dauert die Analyse?'],
    ['ich', 'Rund zwei Wochen. Danach habt ihr schwarz auf weiß, was sich lohnt und was nicht.'],
    ['s1', 'Und was kostet das ungefähr?'],
    ['ich', 'Ich schicke dir morgen einen Budget Indicator. Das ist eine unverbindliche Planungszahl, damit ihr wisst, in welcher Größenordnung wir uns bewegen.'],
    ['s1', 'Gut. Bis wann könnt ihr starten, wenn wir zusagen?'],
    ['ich', 'Frühestens in drei Wochen, ich habe derzeit noch ein Projekt laufen.'],
    ['s2', 'Das passt. Im November ist bei uns ohnehin weniger los.'],
    ['s1', 'Dann halten wir fest: Du schickst den Budget Indicator, wir klären den Datenschutz intern.'],
    ['ich', 'Genau. Und ihr schickt mir drei typische Anfragen als Beispiel, natürlich ohne Kundennamen.'],
    ['s2', 'Machen wir. Wir bereiten die bis Freitag vor.'],
    ['s1', 'Ich würde noch gern wissen, ob ihr auch mit unserem alten Warenwirtschaftssystem arbeiten könnt.'],
    ['ich', 'Das prüfe ich in der Analyse. Meistens gibt es eine Schnittstelle oder zumindest einen Export.'],
    ['ich', 'Wenn nicht, bauen wir einen Zwischenschritt über eine CSV-Datei.'],
    ['s1', 'Okay. Dann vielen Dank für die ehrliche Einschätzung.'],
    ['s2', 'Danke dir, das war sehr hilfreich.'],
    ['ich', 'Ich danke euch. Bis Freitag!'],
  ];
  const wochenplanung = [
    ['ich', 'Starten wir mit dem Stand vom letzten Mal. Was ist von der Liste noch offen?'],
    ['s1', 'Die Anbindung an das Postfach läuft, aber die Freigabe durch den Chef fehlt noch.'],
    ['ich', 'Gut, die holen wir diese Woche ein.'],
    ['s1', 'Dann brauche ich bis Mittwoch die Zugangsdaten für das Testsystem.'],
    ['ich', 'Schicke ich dir heute Abend.'],
    ['s1', 'Perfekt. Dann kann ich am Donnerstag die erste Version zeigen.'],
    ['ich', 'Super. Dann planen wir am Freitag die Abnahme.'],
  ];
  const kurz = [
    ['ich', 'Kurz zum Ablauf heute: erst die Zahlen, dann die nächsten Schritte.'],
    ['s1', 'Passt für mich. Ich habe die Auswertung schon vorbereitet.'],
    ['ich', 'Dann legen wir los.'],
  ];

  /** Verteilt Segmente über die Gesamtdauer, Länge nach Wortzahl. */
  function baueSegmente(liste, gesamt) {
    const d = liste.map(([, t]) => Math.max(2, t.split(/\s+/).length * 0.42));
    const faktor = Math.max(1, gesamt / d.reduce((a, b) => a + b, 0));
    let start = 0;
    return liste.map(([sprecher, text], i) => {
      const seg = { start: Math.round(start * 10) / 10, ende: Math.round((start + d[i]) * 10) / 10, sprecher, text };
      start += d[i] * faktor;
      return seg;
    });
  }

  const segs = {
    t1: baueSegmente(erstgespraech, 2140),
    t2: baueSegmente(wochenplanung, 4120),
    t6: baueSegmente(kurz, 410),
  };
  const namen = { t1: { s1: 'Frau Krüger' }, t2: {}, t6: {} };

  const mz = {
    dienste: {
      whisper: { status: 'bereit', text: 'Whisper large-v3-turbo, läuft auf dem Mac' },
      llm: { status: 'bereit', text: 'Qwen3 4B, lokal' },
      sprecher: { status: 'startet', text: 'Modell wird geladen' },
    },
    rechte: { mikrofon: 'ja', bedienungshilfen: 'nein', bildschirm: 'offen' },
    einstellungen: {
      taste: 'rechte-option', sprache: 'de', aufraeumen: true, einfuegen: true, toene: true, systemton: true,
      woerter: ['Claude Code', 'n8n', 'Kenzo Weiss', 'AssemblyAI', 'Budget Indicator'],
      ersetzungen: [{ von: 'Cloud Code', nach: 'Claude Code' }, { von: 'en acht en', nach: 'n8n' }],
    },
    aufnahme: { art: null, seit: 0, titel: '' },
    diktate: [
      { id: 'd1', zeit: jetzt - 12 * MIN, dauer: 4.2, app: 'Slack', roh: 'ähm kannst du mir bitte bis morgen die zahlen aus dem angebot schicken', text: 'Kannst du mir bitte bis morgen die Zahlen aus dem Angebot schicken?' },
      { id: 'd2', zeit: jetzt - 100 * MIN, dauer: 11.8, app: 'Mail', roh: 'hallo frau krüger vielen dank für das gespräch heute ich schicke ihnen morgen den budget indicator zu', text: 'Hallo Frau Krüger, vielen Dank für das Gespräch heute. Ich schicke Ihnen morgen den Budget Indicator zu.' },
      { id: 'd3', zeit: jetzt - 3 * STD, dauer: 8.1, app: 'Claude Code', roh: 'bau mir bitte eine kleine übersicht für die letzten diktate hell und mit viel luft', text: 'Bau mir bitte eine kleine Übersicht für die letzten Diktate, hell und mit viel Luft.' },
      { id: 'd4', zeit: jetzt - TAG - 5 * STD, dauer: 6.4, app: 'Notion', roh: 'idee für das video warum lokale transkription für den mittelstand wichtig ist', text: 'Idee für das Video: Warum lokale Transkription für den Mittelstand wichtig ist.' },
      { id: 'd5', zeit: jetzt - 2 * TAG - 2 * STD, dauer: 2.3, app: 'Terminal', roh: 'Cloud Code starten', text: 'Claude Code starten' },
      { id: 'd6', zeit: jetzt - 9 * TAG, dauer: 5.5, app: 'Notizen', roh: 'äh einkaufen milch brot und die kabel für den monitor', text: 'Einkaufen: Milch, Brot und die Kabel für den Monitor.' },
    ],
    transkripte: [
      { id: 't1', titel: 'Erstgespräch Müller Maschinenbau', zeit: jetzt - 2 * STD, dauer: 2140, quelle: 'meeting', status: 'fertig', schritt: '', fortschritt: 1, fehler: '', woerter: 4812, sprecher: ['ich', 's1', 's2'] },
      { id: 't3', titel: 'Interview-Aufnahme.m4a', zeit: jetzt - 20 * MIN, dauer: 1860, quelle: 'datei', status: 'laeuft', schritt: 'Sprache wird erkannt, Teil 3 von 7', fortschritt: 0.42, fehler: '', woerter: 0, sprecher: [] },
      { id: 't4', titel: 'Podcast-Folge-42.mp3', zeit: jetzt - 18 * MIN, dauer: 3120, quelle: 'datei', status: 'wartet', schritt: '', fortschritt: 0, fehler: '', woerter: 0, sprecher: [] },
      { id: 't2', titel: 'Wochenplanung', zeit: jetzt - TAG - 3 * STD, dauer: 4120, quelle: 'meeting', status: 'fertig', schritt: '', fortschritt: 1, fehler: '', woerter: 9214, sprecher: ['ich', 's1'] },
      { id: 't5', titel: 'Kaputte-Aufnahme.wav', zeit: jetzt - TAG - 6 * STD, dauer: 0, quelle: 'datei', status: 'fehler', schritt: '', fortschritt: 0, fehler: 'Die Datei enthält keine hörbare Tonspur.', woerter: 0, sprecher: [] },
      { id: 't6', titel: 'Rückruf Lieferant.mp4', zeit: jetzt - 3 * TAG, dauer: 410, quelle: 'datei', status: 'fertig', schritt: '', fortschritt: 1, fehler: '', woerter: 982, sprecher: ['ich', 's1'] },
    ],
    speicherort: '~/Library/Application Support/Koe',
  };

  const push = () => window.koe.zustand(structuredClone(mz));
  const trById = (id) => mz.transkripte.find((t) => t.id === id);

  /** Lässt ein Transkript fortschreiten, bis es fertig ist. */
  function simuliere(id, schritt = 0.05) {
    const iv = setInterval(() => {
      const t = trById(id);
      if (!t) return clearInterval(iv);
      t.status = 'laeuft';
      t.fortschritt = Math.min(1, t.fortschritt + schritt);
      t.schritt = t.fortschritt < 0.5 ? 'Mikrofon wird transkribiert' : t.fortschritt < 0.8 ? 'Mac-Ton wird transkribiert' : 'Sprecher werden getrennt';
      if (t.fortschritt >= 1) {
        clearInterval(iv);
        t.status = 'fertig';
        t.woerter = 120;
        t.sprecher = ['ich', 's1'];
        segs[id] = baueSegmente(kurz, t.dauer || 60);
        namen[id] = {};
      }
      push();
    }, 500);
  }
  simuliere('t3', 0.004);

  // Pegel
  let pegelTimer = null;
  function pegelStart() {
    let ph = 0;
    pegelTimer = setInterval(() => {
      ph += 0.18;
      const mikro = Math.max(0, Math.min(1, 0.42 + Math.sin(ph) * 0.2 + (Math.random() - 0.4) * 0.35));
      const system = Math.max(0, Math.min(1, 0.3 + Math.sin(ph * 0.6 + 1) * 0.25 + (Math.random() - 0.5) * 0.25));
      window.koe.pegel({ mikro, system });
    }, 66);
  }
  const pegelStopp = () => { clearInterval(pegelTimer); pegelTimer = null; };

  setTimeout(() => { mz.dienste.sprecher = { status: 'bereit', text: 'pyannote, lokal' }; push(); }, 4000);

  mockSenden = (cmd, d) => {
    console.info('[mock] →', cmd, d);
    switch (cmd) {
      case 'bereit':
        setTimeout(push, 40);
        break;
      case 'einstellungen.speichern':
        mz.einstellungen = d.einstellungen;
        push();
        break;
      case 'meeting.start':
        mz.aufnahme = { art: 'meeting', seit: Date.now(), titel: d.titel || 'Meeting' };
        push();
        pegelStart();
        break;
      case 'meeting.stop': {
        const dauer = Math.round((Date.now() - mz.aufnahme.seit) / 1000);
        const id = 't' + Date.now();
        mz.transkripte.unshift({ id, titel: mz.aufnahme.titel, zeit: Date.now(), dauer, quelle: 'meeting', status: 'wartet', schritt: '', fortschritt: 0, fehler: '', woerter: 0, sprecher: [] });
        mz.aufnahme = { art: null, seit: 0, titel: '' };
        pegelStopp();
        push();
        setTimeout(() => simuliere(id, 0.1), 800);
        break;
      }
      case 'meeting.verwerfen':
        mz.aufnahme = { art: null, seit: 0, titel: '' };
        pegelStopp();
        push();
        break;
      case 'datei.waehlen': {
        const id = 't' + Date.now();
        mz.transkripte.unshift({ id, titel: 'Neue-Datei.mp3', zeit: Date.now(), dauer: 900, quelle: 'datei', status: 'wartet', schritt: '', fortschritt: 0, fehler: '', woerter: 0, sprecher: [] });
        push();
        window.koe.meldung({ text: 'Datei hinzugefügt (Mock)', art: 'info' });
        setTimeout(() => simuliere(id, 0.08), 800);
        break;
      }
      case 'transkript.laden':
        setTimeout(() => window.koe.transkript({ id: d.id, segmente: segs[d.id] ?? [], namen: namen[d.id] ?? {} }), 120);
        break;
      case 'transkript.umbenennen': {
        const t = trById(d.id);
        if (t) t.titel = d.titel;
        push();
        break;
      }
      case 'transkript.sprecher':
        namen[d.id] = d.namen;
        window.koe.transkript({ id: d.id, segmente: segs[d.id] ?? [], namen: d.namen });
        break;
      case 'transkript.loeschen':
        mz.transkripte = mz.transkripte.filter((t) => t.id !== d.id);
        push();
        break;
      case 'transkript.exportieren':
        window.koe.meldung({ text: 'Als Markdown gespeichert (Mock)', art: 'info' });
        break;
      case 'diktat.loeschen':
        mz.diktate = mz.diktate.filter((x) => x.id !== d.id);
        push();
        break;
      case 'recht.oeffnen':
        window.koe.meldung({ text: 'Systemeinstellungen geöffnet (Mock)', art: 'info' });
        setTimeout(() => { mz.rechte[d.recht] = 'ja'; push(); }, 1500);
        break;
      case 'dienste.neustart':
        for (const k of Object.keys(mz.dienste)) mz.dienste[k].status = 'startet';
        push();
        setTimeout(() => { for (const k of Object.keys(mz.dienste)) mz.dienste[k].status = 'bereit'; push(); }, 2500);
        break;
      case 'ordner.oeffnen':
      case 'transkript.finder':
        window.koe.meldung({ text: 'Im Finder geöffnet (Mock)', art: 'info' });
        break;
      default:
        break; // kopieren: nichts zu tun
    }
  };

  window.__koeMock = { zustand: mz, push, simuliere };
}


/* ---------- Start ---------- */

if (!BRIDGE) startMock();
senden('bereit');
