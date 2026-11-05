import net from 'node:net';
// Transparent local routing only. Authentication and REST responses come from
// the actual upstream services; no SQL, user/session or table-result adapter.
import http from 'node:http';
const routes=[['/auth/v1',process.env.AUTH_HOST,9999],['/rest/v1',process.env.REST_HOST,3000],['/storage/v1',process.env.STORAGE_HOST,5000]];
if(routes.some(([,host])=>!/^taskfold-full-schema-[a-f0-9]{8}-(auth|rest|storage)$/.test(host??''))||!process.env.PUBLIC_KEY)throw Error('Owned upstreams required');
http.createServer((req,res)=>{
 const path=new URL(req.url,'http://local.invalid');
 const route=routes.find(([prefix])=>path.pathname===prefix||path.pathname.startsWith(prefix+'/'));
 if(!route||![process.env.PUBLIC_KEY,process.env.SERVER_KEY].filter(Boolean).includes(req.headers.apikey)){res.writeHead(403);res.end('{}');return}
 const [prefix,hostname,port]=route;
 const headers={...req.headers,host:hostname+':'+port};delete headers.connection;
 const upstream=http.request({hostname,port,method:req.method,path:(path.pathname.slice(prefix.length)||'/')+path.search,headers,timeout:30000},reply=>{
  res.writeHead(reply.statusCode,reply.headers);reply.pipe(res);
 });
 upstream.on('timeout',()=>upstream.destroy());upstream.on('error',()=>{if(res.headersSent)res.destroy();else{res.writeHead(503);res.end('{"error":"Local upstream unavailable"}')}});
 req.on('aborted',()=>upstream.destroy());req.pipe(upstream);
}).listen(3001,'0.0.0.0');

if(!/^taskfold-full-schema-[a-f0-9]{8}-db$/.test(process.env.DB_HOST??''))throw Error('Owned database required');
// Loopback-only publication for the read-only official CLI advisors.
net.createServer(client=>{
 const upstream=net.connect(5432,process.env.DB_HOST);client.pipe(upstream);upstream.pipe(client);
 client.on('error',()=>upstream.destroy());upstream.on('error',()=>client.destroy());
 client.on('close',()=>upstream.destroy());upstream.on('close',()=>client.destroy());
}).listen(3002,'0.0.0.0');
