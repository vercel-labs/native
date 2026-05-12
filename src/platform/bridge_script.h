#ifndef ZERO_NATIVE_BRIDGE_SCRIPT_H
#define ZERO_NATIVE_BRIDGE_SCRIPT_H

#define ZERO_NATIVE_BRIDGE_SCRIPT \
    "(function(){" \
    "if(window.zero&&window.zero.invoke){return;}" \
    "var pending=new Map();" \
    "var listeners=new Map();" \
    "var nextId=1;" \
    "function post(message){" \
    "if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.zeroNativeBridge){window.webkit.messageHandlers.zeroNativeBridge.postMessage(message);return;}" \
    "if(window.zeroNativeCefBridge&&window.zeroNativeCefBridge.postMessage){window.zeroNativeCefBridge.postMessage(message);return;}" \
    "throw new Error('zero-native bridge transport is unavailable');" \
    "}" \
    "function complete(response){" \
    "var id=response&&response.id!=null?String(response.id):'';" \
    "var entry=pending.get(id);" \
    "if(!entry){return;}" \
    "pending.delete(id);" \
    "if(response.ok){entry.resolve(response.result===undefined?null:response.result);return;}" \
    "var errorInfo=response.error||{};" \
    "var error=new Error(errorInfo.message||'Native command failed');" \
    "error.code=errorInfo.code||'internal_error';" \
    "entry.reject(error);" \
    "}" \
    "function invoke(command,payload){" \
    "if(typeof command!=='string'||command.length===0){return Promise.reject(new TypeError('command must be a non-empty string'));}" \
    "var id=String(nextId++);" \
    "var envelope=JSON.stringify({id:id,command:command,payload:payload===undefined?null:payload});" \
    "return new Promise(function(resolve,reject){" \
    "pending.set(id,{resolve:resolve,reject:reject});" \
    "try{post(envelope);}catch(error){pending.delete(id);reject(error);}" \
    "});" \
    "}" \
    "function resourceUrl(resource){" \
    "if(typeof resource==='string'){return resource;}" \
    "if(resource&&typeof resource.url==='string'){return resource.url;}" \
    "throw new TypeError('resource must be a URL string or resource descriptor');" \
    "}" \
    "function resourceFetch(resource,init){return fetch(resourceUrl(resource),init);}" \
    "function resourceArrayBuffer(resource,init){return resourceFetch(resource,init).then(function(response){if(!response.ok){throw new Error('Resource fetch failed: '+response.status);}return response.arrayBuffer();});}" \
    "function resourceBlob(resource,init){return resourceFetch(resource,init).then(function(response){if(!response.ok){throw new Error('Resource fetch failed: '+response.status);}return response.blob();});}" \
    "function resourceStream(resource,init){return resourceFetch(resource,init).then(function(response){if(!response.ok){throw new Error('Resource fetch failed: '+response.status);}return response.body;});}" \
    "function selector(value){return typeof value==='number'?{id:value}:{label:String(value)};}" \
    "function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}" \
    "function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}" \
    "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}" \
    "var windows=Object.freeze({" \
    "create:function(options){return invoke('zero-native.window.create',options||{});}," \
    "list:function(){return invoke('zero-native.window.list',{});}," \
    "focus:function(value){return invoke('zero-native.window.focus',selector(value));}," \
    "close:function(value){return invoke('zero-native.window.close',selector(value));}" \
    "});" \
    "var dialogs=Object.freeze({" \
    "openFile:function(options){return invoke('zero-native.dialog.openFile',options||{});}," \
    "saveFile:function(options){return invoke('zero-native.dialog.saveFile',options||{});}," \
    "showMessage:function(options){return invoke('zero-native.dialog.showMessage',options||{});}" \
    "});" \
    "var resources=Object.freeze({url:resourceUrl,fetch:resourceFetch,arrayBuffer:resourceArrayBuffer,blob:resourceBlob,stream:resourceStream});" \
    "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,windows:windows,dialogs:dialogs,resources:resources,_complete:complete,_emit:emit}),configurable:false});" \
    "})();"

#endif
