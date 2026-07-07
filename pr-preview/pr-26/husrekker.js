// Husrekker på kartet: normalisering av husrekke-json (husrekker/polygoner/)
// og konvertering fra EUREF89/UTM sone 33 (EPSG:25833, øst/nord i meter) til
// WGS84 lat/lng som Leaflet bruker. Ingen Leaflet/DOM-avhengighet, så modulen
// testes med Node (frontend/test/husrekker.test.mjs).

// Invers transversal Mercator (standard serieutvikling, Snyder/USGS) for
// sone 33 (sentralmeridian 15° øst). GRS80-ellipsoiden (EUREF89) – avviket
// mot WGS84 er på cm-nivå og uten betydning på tomteskala. proj4 ville vært
// ~80 kB for akkurat denne ene retningen i denne ene sonen.
const A=6378137, F=1/298.257222101, K0=0.9996, E2=F*(2-F), LON0=15;

export function utm33TilLatLng(oest,nord){
  const x=oest-500000, mu=(nord/K0)/(A*(1-E2/4-3*E2*E2/64-5*E2*E2*E2/256));
  const e1=(1-Math.sqrt(1-E2))/(1+Math.sqrt(1-E2));
  const phi1=mu
    +(3*e1/2-27*e1**3/32)*Math.sin(2*mu)
    +(21*e1*e1/16-55*e1**4/32)*Math.sin(4*mu)
    +(151*e1**3/96)*Math.sin(6*mu)
    +(1097*e1**4/512)*Math.sin(8*mu);
  const ep2=E2/(1-E2), cos1=Math.cos(phi1), tan1=Math.tan(phi1);
  const c1=ep2*cos1*cos1, t1=tan1*tan1;
  const s2=1-E2*Math.sin(phi1)**2;
  const n1=A/Math.sqrt(s2), r1=A*(1-E2)/(s2*Math.sqrt(s2));
  const d=x/(n1*K0);
  const lat=phi1-(n1*tan1/r1)*(d*d/2
    -(5+3*t1+10*c1-4*c1*c1-9*ep2)*d**4/24
    +(61+90*t1+298*c1+45*t1*t1-252*ep2-3*c1*c1)*d**6/720);
  const lon=(d-(1+2*t1+c1)*d**3/6
    +(5-2*c1+28*t1-3*c1*c1+8*ep2+24*t1*t1)*d**5/120)/cos1;
  return { lat: lat*180/Math.PI, lng: LON0+lon*180/Math.PI };
}

// Normaliserer ett husrekke-objekt {navn, crs, polygon:[[øst,nord],...]} til
// {navn, punkter:[{lat,lng},...]}. Kaster med norsk melding ved ukjent
// koordinatsystem eller for få punkter – aldri stille feil projeksjon.
// Manglende crs antas å være EPSG:25833. Et (tilnærmet) duplisert sluttpunkt
// likt startpunktet droppes (dataene lukker polygonet med noen cm avvik);
// Leaflet lukker polygonet selv.
const LUKKE_TOLERANSE_M=0.5;
export function normaliserHusrekke(obj){
  if(!obj || !Array.isArray(obj.polygon))
    throw new Error('Ugyldig husrekke – forventet {navn, crs, polygon: [[øst, nord], ...]}.');
  const crs=obj.crs ?? 'EPSG:25833';
  if(crs!=='EPSG:25833')
    throw new Error(`Ukjent koordinatsystem «${crs}» – forventet EPSG:25833.`);
  const pkt=obj.polygon.map(p=>{
    if(!Array.isArray(p)||p.length!==2||!Number.isFinite(p[0])||!Number.isFinite(p[1]))
      throw new Error('Ugyldig punkt i polygonet – forventet [øst, nord] i meter.');
    return p;
  });
  if(pkt.length>1 && Math.hypot(pkt[pkt.length-1][0]-pkt[0][0], pkt[pkt.length-1][1]-pkt[0][1])<LUKKE_TOLERANSE_M)
    pkt.pop();
  if(pkt.length<3) throw new Error('Polygonet må ha minst 3 punkter.');
  return { navn: typeof obj.navn==='string' ? obj.navn : '', punkter: pkt.map(([e,n])=>utm33TilLatLng(e,n)) };
}
