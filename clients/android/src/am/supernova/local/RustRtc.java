package am.supernova.local;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import org.webrtc.*;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

final class RustRtc {
    static final int PERMISSIONS = 711;
    interface Sender { boolean send(String peer,String id,JSONObject signal); }
    private final Activity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Sender sender;
    private final Runnable changed;
    private static boolean initialized;
    String phase="idle",status="",peer="",id="";
    boolean video,initiator,muted,cameraDisabled;
    private String iceUrls="",iceUser="",icePassword="";
    private PeerConnectionFactory factory;
    private EglBase egl;
    private PeerConnection connection;
    private CameraVideoCapturer capturer;
    private SurfaceTextureHelper texture;
    private AudioSource audioSource;
    private VideoSource videoSource;
    private AudioTrack audioTrack;
    private VideoTrack localTrack,remoteTrack;
    SurfaceViewRenderer localView,remoteView;
    private AudioManager audioManager;
    private int previousMode;
    private boolean oldSpeaker, audioConfigured, localDescriptionSent, remoteDescriptionSet;
    private final List<IceCandidate> localIce=new ArrayList<>(),remoteIce=new ArrayList<>();
    private Runnable deadline,permissionContinuation;

    RustRtc(Activity activity,Sender sender,Runnable changed) {
        this.activity=activity;this.sender=sender;this.changed=changed;
    }

    boolean active(){return !"idle".equals(phase);}
    private static JSONObject signal(String kind,Object... fields) {
        try {JSONObject value=new JSONObject().put("kind",kind);
            for(int i=0;i<fields.length;i+=2)value.put((String)fields[i],fields[i+1]);
            return value;
        }catch(Exception error){throw new IllegalArgumentException(error);}
    }
    private boolean transmit(JSONObject value){return sender.send(peer,id,value);}
    private void changed(){changed.run();}

    void dial(String peer,boolean video,String urls,String username,String password) {
        if(active()||peer.isEmpty())return;
        this.peer=peer;this.video=video;id=UUID.randomUUID().toString();initiator=true;
        iceUrls=urls;iceUser=username;icePassword=password;
        phase="outgoing";status="Вызов…";changed();
        if(!transmit(signal("invite","video",video))){finish("Не удалось отправить вызов");return;}
        timeout(45);
    }

    void receive(JSONObject event,String urls,String username,String password) {
        JSONObject value=event.optJSONObject("signal");if(value==null)return;
        String from=event.optString("peer"),call=event.optString("id"),kind=value.optString("kind");
        if("call_delivery".equals(event.optString("event"))){
            if(active()&&peer.equals(from)&&id.equals(call)&&!kind.equals("ice")&&!kind.equals("hangup")&&!kind.equals("reject")&&!kind.equals("busy"))
                finish(event.optString("error","Сигнал не доставлен"));
            return;
        }
        if("invite".equals(kind)){
            if(active()){
                if(!id.equals(call)||!peer.equals(from))sender.send(from,call,signal("busy"));
                return;
            }
            peer=from;id=call;video=value.optBoolean("video");initiator=false;
            iceUrls=urls;iceUser=username;icePassword=password;phase="incoming";
            status=video?"Входящий видеозвонок":"Входящий аудиозвонок";changed();timeout(45);
            return;
        }
        if(!active()||!peer.equals(from)||!id.equals(call))return;
        switch(kind){
            case "accept":
                if(initiator&&phase.equals("outgoing")){
                    phase="connecting";status="Подключение…";changed();timeout(60);
                    requireMedia(()->makeSdp(true));
                }break;
            case "offer":
                if(!initiator&&phase.equals("connecting"))applyRemote(value.optString("sdp"),SessionDescription.Type.OFFER);
                break;
            case "answer":
                if(initiator&&phase.equals("connecting"))applyRemote(value.optString("sdp"),SessionDescription.Type.ANSWER);
                break;
            case "ice":
                int line=value.optInt("line",-1);if(line<0||line>=64)return;
                IceCandidate candidate=new IceCandidate(value.isNull("mid")?null:value.optString("mid"),line,value.optString("candidate"));
                if(remoteDescriptionSet&&connection!=null)connection.addIceCandidate(candidate);
                else if(remoteIce.size()<128)remoteIce.add(candidate);
                break;
            case "reject":finish("Вызов отклонён");break;
            case "busy":finish("Собеседник занят");break;
            case "hangup":finish("Звонок завершён");break;
        }
    }

    void answer(){
        if(!phase.equals("incoming"))return;
        phase="connecting";status="Подключение…";changed();timeout(60);
        requireMedia(()->{if(!transmit(signal("accept")))finish("Не удалось ответить");});
    }
    void hangup(){
        if(!active())return;
        transmit(signal(phase.equals("incoming")?"reject":"hangup"));
        finish("Звонок завершён");
    }
    void toggleMute(){muted=!muted;if(audioTrack!=null)audioTrack.setEnabled(!muted);changed();}
    void toggleCamera(){cameraDisabled=!cameraDisabled;if(localTrack!=null)localTrack.setEnabled(!cameraDisabled);changed();}

    private void timeout(int seconds){
        if(deadline!=null)main.removeCallbacks(deadline);
        String expected=id;
        deadline=()->{if(active()&&id.equals(expected)&&!phase.equals("connected")){
            transmit(signal("hangup"));finish("Время ожидания истекло");
        }};
        main.postDelayed(deadline,seconds*1000L);
    }

    private void requireMedia(Runnable continuation){
        List<String> missing=new ArrayList<>();
        if(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED)missing.add(Manifest.permission.RECORD_AUDIO);
        if(video&&activity.checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)missing.add(Manifest.permission.CAMERA);
        if(missing.isEmpty()){setup(continuation);return;}
        permissionContinuation=continuation;
        activity.requestPermissions(missing.toArray(new String[0]),PERMISSIONS);
    }

    void permissions(int[] grants){
        Runnable continuation=permissionContinuation;permissionContinuation=null;
        if(continuation==null||!phase.equals("connecting"))return;
        for(int result:grants)if(result!=PackageManager.PERMISSION_GRANTED){fail("Нет разрешения на микрофон или камеру");return;}
        if(grants.length==0){fail("Разрешение не предоставлено");return;}
        setup(continuation);
    }

    private List<PeerConnection.IceServer> iceServers(){
        List<PeerConnection.IceServer> result=new ArrayList<>();
        for(String raw:iceUrls.split(",")){
            String url=raw.trim();if(url.isEmpty())continue;
            if(result.size()>=4||url.length()>512||!(url.startsWith("stun:")||url.startsWith("stuns:")||url.startsWith("turn:")||url.startsWith("turns:")))
                throw new IllegalArgumentException("Укажите до четырёх STUN/TURN URL");
            PeerConnection.IceServer.Builder builder=PeerConnection.IceServer.builder(url);
            if(url.startsWith("turn:")||url.startsWith("turns:"))builder.setUsername(iceUser).setPassword(icePassword);
            result.add(builder.createIceServer());
        }
        return result;
    }

    private void setup(Runnable continuation){
        final String expected=id;
        try{
            synchronized(RustRtc.class){
                if(!initialized){
                    PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(activity.getApplicationContext()).createInitializationOptions());
                    initialized=true;
                }
            }
            audioManager=(AudioManager)activity.getSystemService(Context.AUDIO_SERVICE);
            previousMode=audioManager.getMode();oldSpeaker=audioManager.isSpeakerphoneOn();audioConfigured=true;
            audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);audioManager.setSpeakerphoneOn(true);
            egl=EglBase.create();
            factory=PeerConnectionFactory.builder()
                .setVideoEncoderFactory(new DefaultVideoEncoderFactory(egl.getEglBaseContext(),true,true))
                .setVideoDecoderFactory(new DefaultVideoDecoderFactory(egl.getEglBaseContext())).createPeerConnectionFactory();
            PeerConnection.RTCConfiguration config=new PeerConnection.RTCConfiguration(iceServers());
            config.sdpSemantics=PeerConnection.SdpSemantics.UNIFIED_PLAN;
            connection=factory.createPeerConnection(config,new PeerConnection.Observer(){
                @Override public void onSignalingChange(PeerConnection.SignalingState state){}
                @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state){
                    main.post(()->{
                        if(!id.equals(expected)||connection==null)return;
                        switch(state){
                            case CONNECTED:case COMPLETED:
                                if(deadline!=null)main.removeCallbacks(deadline);
                                phase="connected";status="WebRTC-соединение";changed();break;
                            case FAILED:fail("WebRTC: соединение не установлено. Проверьте ICE/TURN.");break;
                            case DISCONNECTED:phase="connecting";status="Восстановление соединения…";changed();timeout(30);break;
                            default:break;
                        }
                    });
                }
                @Override public void onIceConnectionReceivingChange(boolean receiving){}
                @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state){}
                @Override public void onIceCandidate(IceCandidate candidate){
                    main.post(()->{if(!id.equals(expected)||connection==null)return;
                        if(localDescriptionSent)sendIce(candidate);else if(localIce.size()<128)localIce.add(candidate);
                    });
                }
                @Override public void onIceCandidatesRemoved(IceCandidate[] candidates){}
                @Override public void onAddStream(MediaStream stream){}
                @Override public void onRemoveStream(MediaStream stream){}
                @Override public void onDataChannel(DataChannel channel){}
                @Override public void onRenegotiationNeeded(){}
                @Override public void onAddTrack(RtpReceiver receiver,MediaStream[] streams){
                    MediaStreamTrack track=receiver.track();
                    if(track instanceof VideoTrack)main.post(()->attachRemote(expected,(VideoTrack)track));
                }
                @Override public void onTrack(RtpTransceiver transceiver){
                    MediaStreamTrack track=transceiver.getReceiver().track();
                    if(track instanceof VideoTrack)main.post(()->attachRemote(expected,(VideoTrack)track));
                }
            });
            if(connection==null)throw new IllegalStateException("Не удалось создать WebRTC");
            audioSource=factory.createAudioSource(new MediaConstraints());
            audioTrack=factory.createAudioTrack("audio",audioSource);
            connection.addTrack(audioTrack,Collections.singletonList("betelgeuse"));
            if(video){
                CameraEnumerator enumerator=Camera2Enumerator.isSupported(activity)?new Camera2Enumerator(activity):new Camera1Enumerator(false);
                String selected=null;
                for(String name:enumerator.getDeviceNames())if(enumerator.isFrontFacing(name)){selected=name;break;}
                if(selected==null&&enumerator.getDeviceNames().length>0)selected=enumerator.getDeviceNames()[0];
                if(selected==null)throw new IllegalStateException("Камера недоступна");
                capturer=enumerator.createCapturer(selected,null);
                if(capturer==null)throw new IllegalStateException("Камера недоступна");
                texture=SurfaceTextureHelper.create("BetelgeuseCamera",egl.getEglBaseContext());
                videoSource=factory.createVideoSource(false);
                capturer.initialize(texture,activity.getApplicationContext(),videoSource.getCapturerObserver());
                localView=new SurfaceViewRenderer(activity);localView.init(egl.getEglBaseContext(),null);localView.setMirror(true);
                remoteView=new SurfaceViewRenderer(activity);remoteView.init(egl.getEglBaseContext(),null);
                localTrack=factory.createVideoTrack("video",videoSource);
                localTrack.addSink(localView);connection.addTrack(localTrack,Collections.singletonList("betelgeuse"));
                capturer.startCapture(640,480,24);
            }
            changed();continuation.run();
        }catch(Throwable error){fail("WebRTC: "+error.getMessage());}
    }

    private void attachRemote(String expected,VideoTrack track){
        if(!id.equals(expected)||remoteView==null||remoteTrack==track)return;
        if(remoteTrack!=null)remoteTrack.removeSink(remoteView);
        remoteTrack=track;remoteTrack.addSink(remoteView);changed();
    }

    private abstract static class Observer implements SdpObserver {
        @Override public void onCreateSuccess(SessionDescription description){}
        @Override public void onSetSuccess(){}
        @Override public void onCreateFailure(String error){}
        @Override public void onSetFailure(String error){}
    }

    private void makeSdp(boolean offer){
        PeerConnection pc=connection;if(pc==null)return;
        String expected=id;
        SdpObserver observer=new Observer(){
            @Override public void onCreateFailure(String error){main.post(()->failIf(expected,error));}
            @Override public void onCreateSuccess(SessionDescription description){
                main.post(()->{
                    if(!id.equals(expected)||connection!=pc)return;
                    pc.setLocalDescription(new Observer(){
                        @Override public void onSetFailure(String error){main.post(()->failIf(expected,error));}
                        @Override public void onSetSuccess(){main.post(()->{
                            if(!id.equals(expected)||connection!=pc)return;
                            if(!transmit(signal(offer?"offer":"answer","sdp",description.description))){fail("SDP не отправлено");return;}
                            localDescriptionSent=true;
                            for(IceCandidate candidate:localIce)sendIce(candidate);
                            localIce.clear();
                        });}
                    },description);
                });
            }
        };
        if(offer)pc.createOffer(observer,new MediaConstraints());else pc.createAnswer(observer,new MediaConstraints());
    }

    private void applyRemote(String sdp,SessionDescription.Type type){
        PeerConnection pc=connection;if(pc==null||remoteDescriptionSet)return;
        String expected=id;
        pc.setRemoteDescription(new Observer(){
            @Override public void onSetFailure(String error){main.post(()->failIf(expected,error));}
            @Override public void onSetSuccess(){main.post(()->{
                if(!id.equals(expected)||connection!=pc)return;
                remoteDescriptionSet=true;
                for(IceCandidate candidate:remoteIce)pc.addIceCandidate(candidate);
                remoteIce.clear();
                if(type==SessionDescription.Type.OFFER)makeSdp(false);
            });}
        },new SessionDescription(type,sdp));
    }

    private void sendIce(IceCandidate candidate){
        transmit(signal("ice","candidate",candidate.sdp,"mid",candidate.sdpMid==null?JSONObject.NULL:candidate.sdpMid,"line",candidate.sdpMLineIndex));
    }
    private void failIf(String expected,String reason){if(id.equals(expected))fail(reason);}
    private void fail(String reason){if(active())transmit(signal("hangup"));finish(reason);}

    private void finish(String reason){
        if(deadline!=null){main.removeCallbacks(deadline);deadline=null;}
        permissionContinuation=null;id="";peer="";phase="idle";status=reason;
        if(capturer!=null){try{capturer.stopCapture();}catch(Exception ignored){}capturer.dispose();capturer=null;}
        if(localTrack!=null&&localView!=null)localTrack.removeSink(localView);
        if(remoteTrack!=null&&remoteView!=null)remoteTrack.removeSink(remoteView);
        if(connection!=null){connection.close();connection.dispose();connection=null;}
        remoteTrack=null;
        if(localTrack!=null){localTrack.dispose();localTrack=null;}
        if(audioTrack!=null){audioTrack.dispose();audioTrack=null;}
        if(videoSource!=null){videoSource.dispose();videoSource=null;}
        if(audioSource!=null){audioSource.dispose();audioSource=null;}
        if(texture!=null){texture.dispose();texture=null;}
        if(localView!=null){localView.release();localView=null;}
        if(remoteView!=null){remoteView.release();remoteView=null;}
        if(factory!=null){factory.dispose();factory=null;}
        if(egl!=null){egl.release();egl=null;}
        if(audioConfigured){audioManager.setMode(previousMode);audioManager.setSpeakerphoneOn(oldSpeaker);audioConfigured=false;}
        localIce.clear();remoteIce.clear();localDescriptionSent=false;remoteDescriptionSet=false;muted=false;cameraDisabled=false;
        icePassword="";changed();
    }
}
