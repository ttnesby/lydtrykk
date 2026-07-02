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
export function marchingSquares(grid,rows,cols,threshold){
  const segments=[];
  const at=(r,c)=>grid[r*cols+c];
  const lerp=(v0,v1)=>(threshold-v0)/(v1-v0);
  for(let r=0;r<rows-1;r++){
    for(let c=0;c<cols-1;c++){
      const d=at(r,c), cc=at(r,c+1), b=at(r+1,c+1), a=at(r+1,c);
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
