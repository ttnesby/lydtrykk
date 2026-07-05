// Ren geometri for kart-simulatoren (lydnivakart.html): lokal planprojeksjon,
// storsirkel-hjelpere og marching squares. Ingen Leaflet/DOM-avhengighet, så
// modulen kan testes med Node (frontend/test/gridGeo.test.mjs). Punkter inn er
// alt med {lat, lng}; punkter ut er enkle {lat, lng}-objekter (Leaflet godtar
// dem direkte i polyline/imageOverlay-bounds).

// Lokal planar (ekvirektangulær) projeksjon fra et origo – billig og nøyaktig
// nok på tomte-/nabolagsskala, og trenger ikke Leaflet (fungerer i workere).
export function metersPerDeg(lat){
  const mPerDegLat=111320;
  return { mPerDegLat, mPerDegLon: mPerDegLat*Math.cos(lat*Math.PI/180) };
}
export function toLocal(latlng,origin){
  const {mPerDegLat,mPerDegLon}=metersPerDeg(origin.lat);
  return { x:(latlng.lng-origin.lng)*mPerDegLon, y:(latlng.lat-origin.lat)*mPerDegLat };
}
export function fromLocal(x,y,origin){
  const {mPerDegLat,mPerDegLon}=metersPerDeg(origin.lat);
  return { lat:origin.lat + y/mPerDegLat, lng:origin.lng + x/mPerDegLon };
}

// Storsirkel: punktet distM meter fra (lat,lng) i retning brgDeg (0° = nord,
// medurs). Returnerer [lat, lng].
export function destPoint(lat,lng,brgDeg,distM){
  const R=6378137, d=distM/R, b=brgDeg*Math.PI/180, f1=lat*Math.PI/180, l1=lng*Math.PI/180;
  const f2=Math.asin(Math.sin(f1)*Math.cos(d)+Math.cos(f1)*Math.sin(d)*Math.cos(b));
  const l2=l1+Math.atan2(Math.sin(b)*Math.sin(d)*Math.cos(f1),Math.cos(d)-Math.sin(f1)*Math.sin(f2));
  return [f2*180/Math.PI,l2*180/Math.PI];
}

// Peiling fra 'from' til 'to' i grader (0° = nord, medurs, [0, 360)).
export function bearing(from,to){
  const f1=from.lat*Math.PI/180,f2=to.lat*Math.PI/180,dl=(to.lng-from.lng)*Math.PI/180;
  const y=Math.sin(dl)*Math.cos(f2), x=Math.cos(f1)*Math.sin(f2)-Math.sin(f1)*Math.cos(f2)*Math.cos(dl);
  return (Math.atan2(y,x)*180/Math.PI+360)%360;
}

// Marching squares: konturlinjer der rutenettverdien krysser 'threshold'.
// Hjørnene i cellen (r,c)–(r+1,c+1) navngis a=NV b=NØ c=SØ d=SV. Sadelpunkt-
// tilfellene (idx 5 og 10, alle fire kanter kysset) løses ved å sammenligne
// cellens midtverdi (snitt av hjørnene) mot grensen – standardtriks for å
// unngå tvetydig sammenkobling av linjene. Returnerer segmenter i
// (rad, kolonne)-koordinater: [[r0,c0],[r1,c1]].
// NaN markerer maskerte celler (inne i en husrekke – se rutenettStripeSkjermet
// i Lyd.Felt): celler som berører et NaN-hjørne hoppes over, så konturen
// brytes ved husveggen i stedet for å interpolere mot et meningsløst hjørne.
// (±Infinity forekommer bare i rutenett uten pumper, der ingenting tegnes
// uansett – å hoppe over også dem endrer ingenting.)
export function marchingSquares(grid,rows,cols,threshold){
  const segments=[];
  const at=(r,c)=>grid[r*cols+c];
  const lerp=(v0,v1)=>(threshold-v0)/(v1-v0);
  for(let r=0;r<rows-1;r++){
    for(let c=0;c<cols-1;c++){
      const d=at(r,c), cc=at(r,c+1), b=at(r+1,c+1), a=at(r+1,c);
      if(!(Number.isFinite(a)&&Number.isFinite(b)&&Number.isFinite(cc)&&Number.isFinite(d))) continue;
      const idx=(a>threshold?8:0)|(b>threshold?4:0)|(cc>threshold?2:0)|(d>threshold?1:0);
      if(idx===0||idx===15) continue;
      const left=()=>[r+lerp(d,a), c];
      const top=()=>[r+1, c+lerp(a,b)];
      const right=()=>[r+lerp(cc,b), c+1];
      const bottom=()=>[r, c+lerp(d,cc)];
      const pair=(e1,e2)=>segments.push([e1(),e2()]);
      switch(idx){
        case 1: case 14: pair(left,bottom); break;
        case 2: case 13: pair(bottom,right); break;
        case 3: case 12: pair(left,right); break;
        case 4: case 11: pair(top,right); break;
        case 6: case 9: pair(top,bottom); break;
        case 7: case 8: pair(left,top); break;
        case 5: {
          const midt=(a+b+cc+d)/4;
          if(midt>threshold){ pair(left,top); pair(right,bottom); }
          else { pair(top,right); pair(left,bottom); }
          break;
        }
        case 10: {
          const midt=(a+b+cc+d)/4;
          if(midt>threshold){ pair(top,right); pair(left,bottom); }
          else { pair(left,top); pair(right,bottom); }
          break;
        }
      }
    }
  }
  return segments;
}

// Kantsegmenter: marching squares gir åpne kurver der nivåflaten krysser
// rutenettets ytterkant, så et område over grensen som fortsetter utenfor
// rutenettet ser ut som om konturen bare slutter. Denne tegner konturen
// videre langs selve kanten: for hvert nabopar av kantnoder tas den delen
// av kantstykket der (lineært interpolert) verdi er over grensen. Samme
// >-konvensjon og samme (rad, kolonne)-koordinater som marchingSquares, så
// segmentene kan rendres i samme polyline.
//
// 'inset' (i celleenheter, default 0) rykker segmentene innover fra kanten –
// brukes til å nøste flere samtidig mettede grenser som parallelle striper i
// stedet for at de tegnes oppå hverandre. Verdiene samples fortsatt på de
// ekte kantnodene; kun tegnekoordinatene forskyves (og klemmes så hjørnene
// møtes uten haler).
export function boundarySegments(grid,rows,cols,threshold,inset=0){
  const segments=[];
  const at=(r,c)=>grid[r*cols+c];
  const d=Math.min(inset,(rows-1)/2,(cols-1)/2);
  const juster=([r,c])=>[
    Math.min(Math.max(r,d),rows-1-d),
    Math.min(Math.max(c,d),cols-1-d),
  ];
  const emit=(p0,v0,p1,v1)=>{
    if(!(Number.isFinite(v0)&&Number.isFinite(v1))) return;   // NaN = maskert celle (se marchingSquares)
    const o0=v0>threshold, o1=v1>threshold;
    if(!o0&&!o1) return;
    let seg;
    if(o0&&o1) seg=[p0,p1];
    else {
      const t=(threshold-v0)/(v1-v0);
      const kryss=[p0[0]+t*(p1[0]-p0[0]), p0[1]+t*(p1[1]-p0[1])];
      seg=o0 ? [p0,kryss] : [kryss,p1];
    }
    segments.push([juster(seg[0]),juster(seg[1])]);
  };
  for(let c=0;c<cols-1;c++){
    emit([0,c],at(0,c),[0,c+1],at(0,c+1));                          // sørkant
    emit([rows-1,c],at(rows-1,c),[rows-1,c+1],at(rows-1,c+1));      // nordkant
  }
  for(let r=0;r<rows-1;r++){
    emit([r,0],at(r,0),[r+1,0],at(r+1,0));                          // vestkant
    emit([r,cols-1],at(r,cols-1),[r+1,cols-1],at(r+1,cols-1));      // østkant
  }
  return segments;
}
