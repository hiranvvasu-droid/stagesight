// Manage saved sessions without opening or downloading their video.
async function deleteOwnedCloudSession(session){
 if(!identity||session.user_id!==identity.id)throw Error('Sign in to the account that owns this recording.');
 const folder=identity.id+'/'+session.id+'/';
 if(!session.storage_path?.startsWith(folder))throw Error('Recording ownership could not be verified.');
 const metadata='/rest/v1/sessions?id=eq.'+encodeURIComponent(session.id)+'&user_id=eq.'+encodeURIComponent(identity.id);
 await api(metadata,{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({status:'deleting'})});
 await api('/storage/v1/object/recordings',{method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({prefixes:[session.storage_path,folder+'report.json',folder+'visuals.json']})});
 await api(metadata,{method:'DELETE'});
}
function requestSessionDeletion(id){
 const session=sessions.find(s=>s.id===id);if(!session)return;
 modal('<h2>Delete this recording?</h2><p><strong>'+esc(session.title)+'</strong></p><p>This permanently removes the video, saved transcript, AI report, visual data, and session record. Downloaded copies remain on your device.</p><label class="field" for="delete-verification">Type DELETE to enable permanent deletion</label><input type="text" id="delete-verification" autocomplete="off" spellcheck="false"><p id="delete-status" role="status"></p><div class="actions"><button type="button" class="secondary" id="cancel-session-delete">Keep recording</button><button type="button" class="danger" id="confirm-session-delete" disabled>Delete permanently</button></div>');
 const dialog=$('#dialog'),confirm=$('#confirm-session-delete'),cancel=$('#cancel-session-delete'),status=$('#delete-status'),close=$('.close'),verification=$('#delete-verification');
 let busy=false;
 const preventBusyClose=e=>{if(busy)e.preventDefault()};dialog.addEventListener('cancel',preventBusyClose);
 dialog.addEventListener('close',()=>dialog.removeEventListener('cancel',preventBusyClose),{once:true});
 cancel.onclick=()=>dialog.close();
 verification.oninput=()=>{confirm.disabled=verification.value!=='DELETE'};
 confirm.onclick=async()=>{
  if(busy||verification.value!=='DELETE')return;
  busy=true;confirm.disabled=cancel.disabled=close.disabled=true;confirm.textContent='Deleting…';status.textContent='Removing the recording and associated data…';
  try{
   if(session.cloud)await deleteOwnedCloudSession(session);
   else await new Promise((resolve,reject)=>{if(!db){reject(Error('Device storage unavailable.'));return}const tx=db.transaction('sessions','readwrite');tx.objectStore('sessions').delete(id);tx.oncomplete=resolve;tx.onerror=()=>reject(Error('Device deletion failed.'));tx.onabort=()=>reject(Error('Device deletion interrupted.'))});
   sessions=sessions.filter(s=>s.id!==id);dialog.close();render('library');toast('Recording and associated data deleted.');if(session.cloud)await refresh();
  }catch(error){status.textContent='Deletion incomplete. '+error.message+' Keep this page open and retry.';confirm.textContent='Retry deletion';}
  finally{busy=false;confirm.disabled=verification.value!=='DELETE';cancel.disabled=close.disabled=false;}
 };
}
const cardBeforeSessionActions=card;
card=function(session,index){
 let markup=cardBeforeSessionActions(session,index);
 if(session.status==='deleting')markup=markup.replace('UPLOAD INCOMPLETE','DELETION INCOMPLETE').replace('◌ Upload incomplete','◌ Retry deletion');
 if(view!=='library'||(!session.cloud&&!session.blob))return markup;
 // The open control and delete button are siblings, avoiding nested buttons.
 const opener=markup.replace('<article','<div').replace('class="session"','class="session-open"').replace('</article>','</div>');
 return '<article class="session session-manage">'+opener+'<div class="session-manage-actions"><button type="button" class="session-delete" data-delete-session="'+esc(session.id)+'" aria-label="Delete '+esc(session.title)+'">⌫ <span>Delete recording</span></button></div></article>';
};
document.addEventListener('click',event=>{
 const button=event.target.closest('[data-delete-session]');if(!button)return;
 const id=button.dataset.deleteSession;
 if(!id)return;event.preventDefault();event.stopImmediatePropagation();requestSessionDeletion(id);
},true);
// Report deletion already has an associated session ID in its closure; keep it intact.
if(view==='library')render('library');
