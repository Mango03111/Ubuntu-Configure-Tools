/*
 * APP.cc
 *
 *  Created on: 2023年10月31日
 *      Author: antl
 */
#include <fstream>
#include <vector>
#include <omnetpp.h>
#include <string.h>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include "../packet/Packet_m.h"
#include "../packet/LLU_m.h"
#include "../packet/LLM_m.h"
#include "../packet/CCA_m.h"
#include "../Ocs/global.h"

using namespace std;
using namespace omnetpp;

//#define APP_printf_Msg
#ifndef APP_printf_Msg
    ofstream outfile("APP_printf_Msg.txt");
#endif
/**
 * Generates traffic for the network.
 */
class App: public cSimpleModule {
private:
    // configuration
    int myAddress;
    int myRack;
    int numOfNode;
    int numOfRack;
    int threshold_low;
    int threshold_high;

    /* The default value of vlan is 0. Package-level emulation is marked as 0.
     * mouse flow and elephant flow are 1 and 2 respectively*/
    int vlan;

    /* true when only packet-level emulation is required
     * false when packet and flow level emulation is required*/
    bool b_packet_level;

    /* rate of non-uniform traffic in local and Shuffle traffic modes,
     * not work in the uniform traffic mode*/
    int non_uniform_rate;

    /* stride in shuffle mode. The destination node has a larger stride
     * than the source node. stride don't work in other mode*/
    int stride;

    /* Flow is divided into rat flow and elephant flow, and E_flow_rate
     * the proportion of elephant flow.
     * E_flow_rate work when flow level simulation is set up,
     * In other words, the b_packet_level value is false*/
    int E_flow_rate;

    /* traffic mode:
     * 1. uniform traffic
     * 2. loacal traffic
     * 3. shuffle traffic
     * */
    int traffic_mode;

    std::vector<int> destAddresses;
    std::vector< std::vector<simtime_t> > FCT;
    vector<vector<int >> llu_Msg;
    vector<int> llumsg_Pod;
    vector<int> MEMSID_Connection;
    vector<int> MEMS_Down;
    simtime_t tmp_FCT;
    cPar *sendIATime;
    cPar *packetLengthBytes;
    cMessage *sendPacket;
    long pkCounter;
    long flowCounter;
    long counter;

    int destAddress_flow;
    int destRack_flow;
    simtime_t Server_Rate;

    long numSent;
    long numReceived;
    long numReceived_m;
    long numReceived_c;

    cDoubleHistogram latencyStats;
    cOutVector latencyVector;
    cOutVector packetVector;

    cDoubleHistogram FCTStats;
    cOutVector FCTVector;

    cDoubleHistogram m_latencyStats;
    cOutVector m_latencyVector;
    cOutVector m_packetVector;
    cDoubleHistogram m_FCTStats;
    cOutVector m_FCTVector;

    cDoubleHistogram e_latencyStats;
    cOutVector e_latencyVector;
    cOutVector e_packetVector;
    cDoubleHistogram e_FCTStats;
    cOutVector e_FCTVector;



public:
    App();
    virtual ~App();

protected:
    virtual void initialize();
    virtual void handleMessage(cMessage *msg);
    virtual void finish();
    virtual void generateFlow();
    virtual void uniform_traffic();
    virtual void local_traffic(int);
    virtual void shuffle_traffic(int stride, int rate);
    virtual void E_flow_rate_percent(int);
    virtual void packet_level();
    virtual vector<int> llu_array_change(vector<vector<int >> & nums, int r);
    virtual int calculate_llu2cca(vector<int> llm_msg,vector<int> llu_myPod, int threshold_high,int mems_id);
};

Define_Module(App);

App::App() {
    //gentrateFlow = NULL;
    sendPacket = NULL;
}

App::~App() {
    //cancelAndDelete(generateFlow);
    cancelAndDelete(sendPacket);
}

void App::initialize() {
    myAddress = par("address");
    myRack = par("rack_address");
    numOfNode = par("numOfNode");
    numOfRack = par("numOfPod");
    threshold_low = par("threshold_low");
    threshold_high = par("threshold_high");
    E_flow_rate = par("E_flow_rate");
    packetLengthBytes = &par("packetLength");
    EV << "packetlenghth is " << packetLengthBytes->longValue() <<endl;
    sendIATime = &par("sendIaTime");  // volatile parameter
    Server_Rate = par("Server_Rate");
    b_packet_level = par("b_packet_level");
    stride = par("stride");
    non_uniform_rate = par("non_uniform_rate");
    traffic_mode = par("traffic_mode");
    FCT.resize(numOfRack);
    for (int Rack_ID=0; Rack_ID<numOfRack; Rack_ID++){
        FCT[Rack_ID].assign(numOfNode, -1);
    }
    llu_Msg.resize(numOfRack);
    for(int i=0;i<numOfRack;i++){
        llu_Msg[i].assign(numOfRack, 0);
    }
    llumsg_Pod.assign(numOfRack, 0);
    MEMSID_Connection.assign(numOfRack, 0);
    pkCounter = 0;
    flowCounter = 0;
    counter = 0;
    vlan = 0;

    destAddress_flow = -1;
    destRack_flow = -1;

    numSent = 0;
    numReceived = 0;
    numReceived_m = 0;
    numReceived_c = 0;
    WATCH(numSent);
    WATCH(numReceived);

    MEMS_Down.resize(numOfRack);
    for(int i=0;i<numOfRack;i++){
        MEMS_Down[i] = -1;
    }

    latencyStats.setName("Latency");
    latencyStats.setRangeAutoUpper(0);
    latencyVector.setName("Latency");
    packetVector.setName("packet");

    m_FCTStats.setName("m_FCT");
    m_FCTStats.setRangeAutoUpper(0);
    m_FCTVector.setName("m_FCT");

    e_FCTStats.setName("e_FCT");
    e_FCTStats.setRangeAutoUpper(0);
    e_FCTVector.setName("e_FCT");

    FCTStats.setName("FCT");
    FCTStats.setRangeAutoUpper(0);
    FCTVector.setName("FCT");


    m_latencyStats.setName("m_Latency");
    m_latencyStats.setRangeAutoUpper(0);
    m_latencyVector.setName("m_Latency");
    m_packetVector.setName("m_packet");

    e_latencyStats.setName("e_Latency");
    e_latencyStats.setRangeAutoUpper(0);
    e_latencyVector.setName("e_Latency");
    e_packetVector.setName("e_packet");

    sendPacket = new cMessage("sendPacket");

    generateFlow();
    scheduleAt(sendIATime->doubleValue(), sendPacket);

}

/*Uniformly distributed traffic of source node and destination node*/
void App::uniform_traffic(){
    destRack_flow = intuniform(0, numOfRack-1);
    destAddress_flow = intuniform(0, numOfNode-1);
    while (myRack==destRack_flow)// && myAddress==destAddress_flow)
    {
        destAddress_flow = intuniform(0, numOfNode-1);
        destRack_flow = intuniform(0, numOfRack-1);
    }
}

/*rate percent of the traffic is local traffic and the rest is uniform traffic*/
void App::local_traffic(int rate){
    int distribution_number_address = intuniform(1,100);
    if(distribution_number_address <= rate )
    {
        destRack_flow = myRack;
        destAddress_flow = intuniform(0, numOfNode-1);
    }
    else
    {
        destAddress_flow = intuniform(0, numOfNode-1);
        destRack_flow = intuniform(0, numOfRack-1);
    }

    while (myAddress==destAddress_flow && myRack==destRack_flow)
    {
        destAddress_flow = intuniform(0, numOfNode-1);
    }
}

/* rate percent of the traffic is shuffle traffic
 * which The destination node has a larger stride
 * than the source node, the rest is uniform traffic*/
void App::shuffle_traffic(int stride, int rate){
    int distribution_number_flow = intuniform(1,100);
    if(distribution_number_flow <= rate )
    {
        destRack_flow = (myRack + stride) % numOfRack;
        destAddress_flow = intuniform(0, numOfNode-1);
    }
    else
    {
        destRack_flow = intuniform(0, numOfRack-1);
        destAddress_flow = intuniform(0, numOfNode-1);
    }
    while (myAddress==destAddress_flow) //&& myRack==destRack_flow)
    {
        destAddress_flow = intuniform(0, numOfNode-1);
    }
}

void App::E_flow_rate_percent(int rate){
    int flow_size;
    int distribution_number = intuniform(1,100);//
    int packetsize = 1;



    //DCTCP traffic trace
    if(distribution_number >= rate ){
        flow_size = intuniform(2,4);
        vlan = 1;
    }
    else{
        flow_size = intuniform(800,1000);
        vlan = 2;
    }
    counter = flow_size/packetsize;
    numSent+=flow_size;
}


void App::packet_level(){
    counter = 1;
    numSent++;
}

void App::generateFlow(){
   //Traffic mode, reflecting spatial distribution, source node and destination node spatial layout
   switch(traffic_mode)
   {
      case 1:
          uniform_traffic();
          break;
      case 2:
          local_traffic(non_uniform_rate);
          break;
      case 3:
          shuffle_traffic(stride, non_uniform_rate);
          break;
   }

    // Whether it is package-level simulation
    if(b_packet_level)
    {
        packet_level();
        vlan = 0;
    }
    else
    {
        E_flow_rate_percent(E_flow_rate);
    }

}

vector<int> App::llu_array_change(vector<vector<int >> & nums, int r){
    vector<int> connection(numOfRack,-1); //mems_port link
    for(int i=0;i<nums.size();i++){
        for(int j=0;j<nums.size();j++){
            if(nums[i][j] != 0 && nums[i][j] < r){
                connection[i] = 1;                      //connection 存储的是该mems要断开的源(i)
            }
        }
    }
    return connection;
}

int App::calculate_llu2cca(vector<int> llm_msg,vector<int> llu_myPod,int threshold_high,int mems_id){//mems断的，本地tor端口累计数，还需要知道最大的端口对应的目的地
    vector<int> canSetpod;
    int result = -1;
    for(int i=0;i<numOfRack;i++){
        if(llm_msg[i] == 1) canSetpod.push_back(g_MEMS_config[mems_id][i]); //各个目的端口
    }
    for(int j=0;j<canSetpod.size();j++){                            //llu_myPod表示本ToR的对每个目的pod的队列长度
        if(j != myRack && llu_myPod[j] > threshold_high)
            result = j;
    }
    return result;
}

void App::handleMessage(cMessage *msg) {
    if (msg == sendPacket) {
        //send message
        scheduleAt(simTime()+sendIATime->doubleValue()*counter, sendPacket);
        for (int i=counter;i>0;i--){
            char pkname[40];
            sprintf(pkname, "pk-%d,%d-to-%d,%d-vlan%d-flow%ld-#%ld", myRack, myAddress, destRack_flow, destAddress_flow, vlan, flowCounter, i);
            Packet *pk = new Packet(pkname);
            pk->setByteLength(packetLengthBytes->longValue());
            pk->setSrcAddr(myAddress);
            pk->setSrcRack(myRack);
            pk->setDestAddr(destAddress_flow);
            pk->setDestRack(destRack_flow);
            pk->setVlan(vlan);
            pk->setFlowId(flowCounter);
            pk->setPkId(i);
            send(pk, "out");
        }
        generateFlow();
        flowCounter++;
    } else {
        string str_msgName = msg->getName();
        if(str_msgName == "Llu_Msg"){                                               //收到ocs的llu，确定要断开的链路，发送llm请求给其他pod的0server
#ifndef APP_printf_Msg
            outfile << "sendIATime == " << sendIATime->doubleValue() << endl ;
            outfile << "threshold_low  == " << threshold_low  << endl ;
    outfile << "simtime () == " << simTime() << " RACK : " << myRack <<"  == APP receive msg Llu_Msg " << endl ;
#endif
            LLU *llu = check_and_cast<LLU *>(msg);
            llu_Msg = llu->getLlu_Msg();                                            //所对应ocs的llu信息
            vector<int> MEMS_CONFIG = g_MEMS_config[myRack];                        //该mems现在对应的配置关系
            MEMS_Down = llu_array_change(llu_Msg,threshold_low);                    //返回低于阈值的mems的端口 的 连接关系
            int MEMS_ID = myRack;
            int numOfDownlink = 0;
            for(int i=0;i<MEMS_Down.size();i++){
                if(MEMS_Down[i] == 1) numOfDownlink++;
            }
#ifndef APP_printf_Msg
    outfile << "simtime () == " << simTime() << " RACK : " << myRack <<"  == numOfdownlink  == " << numOfDownlink << endl ;
    for(int i=0;i<llu_Msg.size();i++){
            for(int j=0;j<llu_Msg.size();j++){
                outfile << llu_Msg[i][j] << " " ;
            }
            outfile << endl ;
        }
#endif
            if(numOfDownlink>1){                                                    //断开链路数最少为2才有意义
                for(int i=0; i<MEMS_Down.size(); i++){
                    if(MEMS_Down[i] == 1){                                          //该rack 连接此 mems 的链路利用率低，需要断掉
                        LLM *llm = new LLM();
                        llm->setName("LLM_Msg");
                        llm->setSrcPod(MEMS_ID);                                    //llm向 mems 低链路对应个端口的pod发送；
                        llm->setDstPod(i);                                          //存入一维数组 表示此mems断掉的 个pod id
                        llm->setLLM_Msg(MEMS_Down);
                        send(llm,"out");
                    }
                }
            }
        }
        else if(str_msgName == "Llu_Msg_Pod"){                                      //收集流量
            LLU *llu =  check_and_cast<LLU *>(msg);
            llumsg_Pod = llu->getV1Vector();                                        //存储的应该为 每个tor 对其他tor的 buffer缓存，队列大小
#ifndef APP_printf_Msg
    outfile << "simtime () == " << simTime() << " RACK : " << myRack <<  " APP receive msg Llu_Msg_Pod " << endl ;
    for(int i=0;i<llumsg_Pod.size();i++){
        outfile << llumsg_Pod[i] << " " ;
    }
    outfile << endl;
#endif
        }
        else if(str_msgName == "LLM_Msg"){                                          //收到其他ocs 的控制节点发来的llm，包含了其ocs断开的端口信息，此app也将被断开
#ifndef APP_printf_Msg
    outfile << "simtime () == " << simTime() << " RACK : " << myRack << " APP receive msg LLM_Msg " << endl ;
#endif
            LLM *llm = check_and_cast<LLM *>(msg);
            int MEMS_ID = llm->getSrcPod();
            vector<int> MEMS_downLink = llm->getLLM_Msg();                          //该 mems_id 的断开端口，需要看自己ToR的流量信息
            vector<int> itMEMS_CONFIG = g_MEMS_config[MEMS_ID];                     //该mems 的原本连接关系
            //如果多个都建立请求怎么办？
            int LinkUp_pod = calculate_llu2cca(MEMS_downLink,llumsg_Pod,threshold_high,MEMS_ID);
            if(LinkUp_pod != -1){                                                   //建立cca消息
                CCA *cca = new CCA();
                cca->setName("CCA_Msg");
                cca->setLinkPod1(myRack);
                cca->setLinkPod2(LinkUp_pod);                                       //link_pod 为此app想要建立的链路的目的，应该在MEMS_downLink中 = 1
                //和该mems 中 可以断开的目的地端口建立 LinkUp_pod
                cca->setSrcPod(myRack);
                cca->setDstPod(MEMS_ID);
                send(cca,"out");
#ifndef APP_printf_Msg
    outfile << "simtime () == " << simTime() << " RACK : " << myRack << " APP send CCA_Msg to MEMS : "  << MEMS_ID << " TO --> set " << LinkUp_pod << endl ;
#endif
            }
        }
        else if(str_msgName == "CCA_Msg"){                                          //收到某个 pod 发来的链路建立请求,此时类似controller处理
            CCA *cca = check_and_cast<CCA *>(msg);
#ifndef APP_printf_Msg
    outfile << "simtime () == " << simTime() <<  " RACK : " << myRack <<" APP receive msg CCA_Msg from  " << cca->getSrcPod() << endl ;
#endif
            vector<int> MEMS_CONFIG = g_MEMS_config[myRack];
            int setPort1 = cca->getLinkPod1();                      //发来cca的rack
            int setPort1dest = cca->getLinkPod2();                  //该rack想连接的目的
            int anotherSrc ;
            for(int i=0;i<MEMS_Down.size();i++){
                //如果i是低于阈值的端口（要断的），判断
                if(MEMS_Down[i]==1 && g_MEMS_config[myRack][i] == setPort1dest)
                    anotherSrc = i;
            }
            MEMS_Down.assign(numOfRack, -1);
            CCA *cca_MEMS = new CCA();
            cca_MEMS->setName("Link_Change");
            cca_MEMS->setLinkPod1(setPort1);                                        //存入需要更换的一对链路 端口
            cca_MEMS->setLinkPod2(anotherSrc);
            send(cca_MEMS,"out");
        }
        else {
            // Handle incoming packet
            Packet *pk = check_and_cast<Packet *>(msg);
            if (FCT[pk->getSrcRack()][pk->getSrcAddr()]==-1){
                FCT[pk->getSrcRack()][pk->getSrcAddr()]=pk->getTimestamp();
            }else if(pk->getPkId()==1){
                tmp_FCT = pk->getArrivalTime()-FCT[pk->getSrcRack()][pk->getSrcAddr()];
                if (pk->getVlan()==1){
                    m_FCTVector.record(tmp_FCT);
                    m_FCTStats.collect(tmp_FCT);
                }else{
                    e_FCTVector.record(tmp_FCT);
                    e_FCTStats.collect(tmp_FCT);
                }
                FCTVector.record(tmp_FCT);
                FCTStats.collect(tmp_FCT);
                FCT[pk->getSrcRack()][pk->getSrcAddr()]=-1;
            }
            if (pk->getVlan()==1){
                simtime_t m_latency = pk->getArrivalTime() - pk->getTimestamp();
                numReceived_m++;
                m_latencyVector.record(m_latency);
                m_latencyStats.collect(m_latency);
                m_packetVector.record(1);
            }
            else{
                simtime_t e_latency = pk->getArrivalTime() - pk->getTimestamp();
                numReceived_c++;
                e_latencyVector.record(e_latency);
                e_latencyStats.collect(e_latency);
                e_packetVector.record(1);
            }
            EV << endl;
            EV <<"Rack:"<<myRack<<",Node:"<<myAddress<<"received packet " << pk->getName() << endl;
            EV << endl;
            EV <<"Rack:"<<myRack<<",Node:"<<myAddress<<"end time"<< simTime() << endl;

            EV << endl;

            // update statistics.
            simtime_t latency = pk->getArrivalTime() - pk->getTimestamp();
            EV << "latency is " <<latency <<endl;
            numReceived++;
            latencyVector.record(latency);
            latencyStats.collect(latency);
            packetVector.record(1);
            delete pk;
        }
    }
}

void App::finish(){
    // This function is called by OMNeT++ at the end of the simulation.
//    EV << "Sent:     " << numSent << endl;
//    EV << "Received: " << numReceived << endl;
//    EV << "Latency, min:    " << latencyStats.getMin() << endl;
//    EV << "Latency, max:    " << latencyStats.getMax() << endl;
//    EV << "Latency, mean:   " << latencyStats.getMean() << endl;
//    EV << "Latency, stddev: " << latencyStats.getStddev() << endl;

    double averagethroughout = numReceived/simTime();
    recordScalar("#average throughout",averagethroughout);

    recordScalar("#sent", numSent);
    recordScalar("#received", numReceived);
    recordScalar("#m_received", numReceived_m);
    recordScalar("#e_received", numReceived_c);

    latencyStats.recordAs("Latency");
    m_latencyStats.recordAs("m_Latency");
    e_latencyStats.recordAs("e_Latency");
    FCTStats.recordAs("FCT");
    m_FCTStats.recordAs("m_FCT");
    e_FCTStats.recordAs("e_FCT");
}





